# nix/pdns-failover-test.nix
#
# PowerDNS PostgreSQL failover resilience test.
#
# Phases:
#   1. Pre-flight (DaemonSet healthy, DNS responding)
#   2. Identify PG primary
#   3. Start background DNS probe (dig every 500ms)
#   4. Kill PG primary pod
#   5. Measure recovery (poll until DNS returns valid SOA)
#   6. Post-failover verify (new primary, RFC2136 write path)
#   7. Cleanup + report
#
# Reports: total downtime (ms), SERVFAIL count, time to first success.
#
# Usage:
#   nix run .#k8s-pdns-failover-test
#
{ pkgs }:
let
  constants = import ./constants.nix;
  testLib = import ./test-lib.nix { };
in
{
  pdnsFailoverTest = pkgs.writeShellApplication {
    name = "k8s-pdns-failover-test";
    runtimeInputs = with pkgs; [
      kubectl
      dnsutils   # dig, nsupdate
      openssh
      coreutils
      bc
      procps
      gnugrep
      gnused
      sshpass
      jq
    ];
    text = ''
      set +e

      ${testLib.colorHelpers}
      ${testLib.timingHelpers}

      CP0_IP="${constants.network.ipv4.cp0}"
      VIP="${constants.pdns.vip}"
      PDNS_NS="${constants.pdns.namespace}"
      SSH_PASS="${constants.ssh.password}"
      TEST_DOMAIN="${builtins.head constants.pdns.domains}"
      PROBE_LOG=$(mktemp /tmp/pdns-probe-XXXXXX.log)

      SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR -o PubkeyAuthentication=no"

      ssh_cmd() {
        sshpass -p "$SSH_PASS" ssh $SSH_OPTS root@"$CP0_IP" "$@"
      }

      kubectl_cmd() {
        ssh_cmd kubectl "$@"
      }

      cleanup() {
        # Kill background probe if running
        if [[ -n "''${PROBE_PID:-}" ]]; then
          kill "$PROBE_PID" 2>/dev/null
          wait "$PROBE_PID" 2>/dev/null
        fi
        rm -f "$PROBE_LOG"
      }
      trap cleanup EXIT

      bold "========================================="
      bold "  PowerDNS PG Failover Resilience Test"
      bold "========================================="
      echo ""

      # ── Phase 1: Pre-flight ─────────────────────────────────────
      phase_header 1 "Pre-flight" 30

      P1_START=$(time_ms)

      DS_READY=$(kubectl_cmd get ds -n "$PDNS_NS" pdns-auth -o jsonpath='{.status.numberReady}' 2>/dev/null)
      DS_DESIRED=$(kubectl_cmd get ds -n "$PDNS_NS" pdns-auth -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)
      if [[ "$DS_READY" != "$DS_DESIRED" || -z "$DS_READY" || "$DS_READY" -eq 0 ]]; then
        error "DaemonSet pdns-auth not healthy: $DS_READY/$DS_DESIRED"
        exit 1
      fi
      result_pass "DaemonSet pdns-auth: $DS_READY/$DS_DESIRED ready" "$(elapsed_ms "$P1_START")"

      SOA=$(dig @"$VIP" "$TEST_DOMAIN" SOA +short +time=3 +tries=1 2>/dev/null)
      if ! echo "$SOA" | grep -q "ns1\.$TEST_DOMAIN"; then
        error "DNS not responding on VIP $VIP for $TEST_DOMAIN"
        exit 1
      fi
      result_pass "DNS responding on VIP: $TEST_DOMAIN SOA OK"

      # ── Phase 2: Identify PG primary ────────────────────────────
      phase_header 2 "Identify PG primary" 15

      P2_START=$(time_ms)

      PRIMARY_POD=$(kubectl_cmd get pods -n postgres -l cnpg.io/instanceRole=primary \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
      if [[ -z "$PRIMARY_POD" ]]; then
        error "Could not identify PG primary pod"
        exit 1
      fi
      result_pass "PG primary: $PRIMARY_POD" "$(elapsed_ms "$P2_START")"

      # ── Phase 3: Start DNS probe ────────────────────────────────
      phase_header 3 "Start DNS probe" 5

      info "  Probing dig @$VIP $TEST_DOMAIN SOA every 500ms"
      info "  Logging to $PROBE_LOG"

      # Background DNS probe — each line: <epoch_ms> <status> <response>
      (
        while true; do
          TS=$(date +%s%N | cut -b1-13)
          RESULT=$(dig @"$VIP" "$TEST_DOMAIN" SOA +short +time=2 +tries=1 2>&1)
          RC=$?
          if [[ $RC -eq 0 ]] && echo "$RESULT" | grep -q "ns1\.$TEST_DOMAIN"; then
            echo "$TS OK $RESULT"
          else
            echo "$TS FAIL $RESULT"
          fi
          sleep 0.5
        done
      ) >> "$PROBE_LOG" &
      PROBE_PID=$!

      # Let probe establish baseline
      sleep 2
      BASELINE=$(grep -c "OK" "$PROBE_LOG" 2>/dev/null || echo 0)
      result_pass "Probe running (PID=$PROBE_PID, baseline OKs=$BASELINE)"

      # ── Phase 4: Kill PG primary ────────────────────────────────
      phase_header 4 "Kill PG primary" 10

      KILL_START=$(time_ms)
      info "  Deleting pod $PRIMARY_POD"
      kubectl_cmd delete pod -n postgres "$PRIMARY_POD" --grace-period=0 2>/dev/null
      result_pass "Deleted $PRIMARY_POD" "$(elapsed_ms "$KILL_START")"

      # ── Phase 5: Measure recovery ───────────────────────────────
      phase_header 5 "Measure recovery" 120

      RECOVERY_START=$(time_ms)
      RECOVERED=false

      # Wait for DNS to start failing (may take a moment)
      sleep 2

      # Poll until DNS returns valid SOA again
      for i in $(seq 1 240); do
        SOA=$(dig @"$VIP" "$TEST_DOMAIN" SOA +short +time=2 +tries=1 2>/dev/null)
        if echo "$SOA" | grep -q "ns1\.$TEST_DOMAIN"; then
          RECOVERED=true
          break
        fi
        sleep 0.5
      done

      RECOVERY_MS=$(elapsed_ms "$RECOVERY_START")

      if $RECOVERED; then
        result_pass "DNS recovered after $(format_ms "$RECOVERY_MS")" "$RECOVERY_MS"
      else
        result_fail "DNS did not recover within 120s" "$RECOVERY_MS"
      fi

      # Analyze probe log for detailed metrics
      TOTAL_PROBES=$(wc -l < "$PROBE_LOG")
      OK_PROBES=$(grep -c "OK" "$PROBE_LOG" 2>/dev/null || echo 0)
      FAIL_PROBES=$(grep -c "FAIL" "$PROBE_LOG" 2>/dev/null || echo 0)

      # Find first FAIL and first OK-after-FAIL for precise timing
      FIRST_FAIL_TS=$(grep "FAIL" "$PROBE_LOG" | head -1 | awk '{print $1}')
      LAST_FAIL_TS=$(grep "FAIL" "$PROBE_LOG" | tail -1 | awk '{print $1}')

      if [[ -n "$FIRST_FAIL_TS" && -n "$LAST_FAIL_TS" ]]; then
        # Find first OK after the last FAIL
        FIRST_OK_AFTER=$(awk -v last="$LAST_FAIL_TS" '$1 > last && $2 == "OK" {print $1; exit}' "$PROBE_LOG")
        if [[ -n "$FIRST_OK_AFTER" ]]; then
          DOWNTIME_MS=$((FIRST_OK_AFTER - FIRST_FAIL_TS))
          info "  Measured downtime: $(format_ms "$DOWNTIME_MS") (first FAIL to first OK after)"
        fi
      fi

      info "  Probe stats: $TOTAL_PROBES total, $OK_PROBES OK, $FAIL_PROBES FAIL"

      # ── Phase 6: Post-failover verify ───────────────────────────
      phase_header 6 "Post-failover verify" 60

      P6_START=$(time_ms)

      # New primary elected
      sleep 5  # give CNPG time to update labels
      NEW_PRIMARY=$(kubectl_cmd get pods -n postgres -l cnpg.io/instanceRole=primary \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
      if [[ -n "$NEW_PRIMARY" && "$NEW_PRIMARY" != "$PRIMARY_POD" ]]; then
        result_pass "New PG primary: $NEW_PRIMARY (was $PRIMARY_POD)" "$(elapsed_ms "$P6_START")"
      elif [[ "$NEW_PRIMARY" == "$PRIMARY_POD" ]]; then
        warn "  PG primary unchanged (pod was recreated with same name)"
        result_pass "PG primary: $NEW_PRIMARY (recreated)" "$(elapsed_ms "$P6_START")"
      else
        result_fail "No PG primary found after failover" "$(elapsed_ms "$P6_START")"
      fi

      # RFC2136 write path works post-failover
      TSIG_KEY=$(kubectl_cmd -n "$PDNS_NS" get secret pdns-credentials \
        -o jsonpath='{.data.tsig-secret}' 2>/dev/null | base64 -d 2>/dev/null)

      if [[ -n "$TSIG_KEY" ]]; then
        FO_DOMAIN="_failover-test.$TEST_DOMAIN"
        nsupdate -y "${constants.pdns.tsigAlgorithm}:${constants.pdns.tsigKeyName}:$TSIG_KEY" <<NSUPDATE_FO_EOF 2>/dev/null
server $VIP
update add $FO_DOMAIN 60 TXT "failover-ok"
send
NSUPDATE_FO_EOF
        if [[ $? -eq 0 ]]; then
          sleep 1
          TXT_VAL=$(dig @"$VIP" "$FO_DOMAIN" TXT +short +time=5 2>/dev/null)
          if echo "$TXT_VAL" | grep -q "failover-ok"; then
            result_pass "RFC2136 write post-failover: OK"
          else
            result_fail "RFC2136 write post-failover: verify failed ($TXT_VAL)"
          fi

          # Cleanup
          nsupdate -y "${constants.pdns.tsigAlgorithm}:${constants.pdns.tsigKeyName}:$TSIG_KEY" <<NSUPDATE_CLEAN_EOF 2>/dev/null
server $VIP
update delete $FO_DOMAIN TXT
send
NSUPDATE_CLEAN_EOF
        else
          result_fail "RFC2136 write post-failover: nsupdate failed"
        fi
      else
        result_fail "Could not read TSIG key for post-failover write test"
      fi

      # DNS resolution stable (5 consecutive successes)
      STABLE_COUNT=0
      for i in $(seq 1 10); do
        SOA=$(dig @"$VIP" "$TEST_DOMAIN" SOA +short +time=2 +tries=1 2>/dev/null)
        if echo "$SOA" | grep -q "ns1\.$TEST_DOMAIN"; then
          STABLE_COUNT=$((STABLE_COUNT + 1))
        else
          STABLE_COUNT=0
        fi
        if [[ $STABLE_COUNT -ge 5 ]]; then
          break
        fi
        sleep 0.5
      done

      if [[ $STABLE_COUNT -ge 5 ]]; then
        result_pass "DNS resolution stable (5 consecutive successes)"
      else
        result_fail "DNS resolution not stable ($STABLE_COUNT/5 consecutive)"
      fi

      # ── Phase 7: Summary ────────────────────────────────────────
      echo ""
      bold "========================================="
      bold "  PowerDNS PG Failover Test Summary"
      bold "========================================="
      echo "  PG primary killed: $PRIMARY_POD"
      echo "  New primary:       ''${NEW_PRIMARY:-unknown}"
      if [[ -n "''${DOWNTIME_MS:-}" ]]; then
        echo "  DNS downtime:      $(format_ms "$DOWNTIME_MS")"
      else
        echo "  DNS downtime:      (could not measure)"
      fi
      echo "  Recovery time:     $(format_ms "$RECOVERY_MS")"
      echo "  Probe stats:       $OK_PROBES OK / $FAIL_PROBES FAIL / $TOTAL_PROBES total"
      if $RECOVERED; then
        success "  Result: PASS"
      else
        error "  Result: FAIL (DNS did not recover)"
      fi
      bold "========================================="

      if ! $RECOVERED; then
        exit 1
      fi
    '';
  };
}
