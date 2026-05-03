# nix/pdns-test.nix
#
# PowerDNS + ACME integration smoke test.
#
# 7-phase test:
#   1. K8s resources (DaemonSet, Service, ArgoCD app)
#   2. Schema bootstrap (Job completed, database exists)
#   3. DNS resolution via VIP
#   4. DNS resolution per-node
#   5. RFC2136 dynamic update (TSIG add/verify/delete)
#   6. cert-manager integration (ClusterIssuer ready)
#   7. nginx TLS (Certificate CR, Ingress hosts)
#
# Usage:
#   nix run .#k8s-pdns-test
#
{ pkgs }:
let
  constants = import ./constants.nix;
  testLib = import ./test-lib.nix { };
in
{
  pdnsTest = pkgs.writeShellApplication {
    name = "k8s-pdns-test";
    runtimeInputs = with pkgs; [
      kubectl
      dnsutils   # dig, nsupdate
      openssh
      coreutils
      jq
      gnugrep
      gnused
    ];
    text = ''
      set +e

      ${testLib.colorHelpers}
      ${testLib.timingHelpers}

      CP0_IP="${constants.network.ipv4.cp0}"
      VIP="${constants.pdns.vip}"
      PDNS_NS="${constants.pdns.namespace}"
      SSH_KEY="''${SSH_KEY:-secrets/ssh-ed25519}"
      DOMAINS=(${builtins.concatStringsSep " " (map (d: ''"${d}"'') constants.pdns.domains)})
      NODE_IPS=(${builtins.concatStringsSep " " (map (n: ''"${constants.network.ipv4.${n}}"'') constants.nodeNames)})

      PASS_COUNT=0
      FAIL_COUNT=0
      TOTAL_START=$(time_ms)

      SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR -i $SSH_KEY"

      ssh_cmd() {
        # shellcheck disable=SC2086,SC2029
        ssh $SSH_OPTS root@"$CP0_IP" "$@"
      }

      kubectl_cmd() {
        local escaped
        # shellcheck disable=SC2059
        escaped="$(printf ' %q' "$@")"
        ssh_cmd "KUBECONFIG=/var/lib/kubernetes/pki/admin-kubeconfig kubectl$escaped"
      }

      check_pass() {
        local msg="$1"
        local ms="''${2:-}"
        PASS_COUNT=$((PASS_COUNT + 1))
        result_pass "$msg" "$ms"
      }

      check_fail() {
        local msg="$1"
        local ms="''${2:-}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        result_fail "$msg" "$ms"
      }

      # ── Phase 1: K8s Resources ───────────────────────────────────
      phase_header 1 "K8s Resources" 60

      P1_START=$(time_ms)

      # DaemonSet ready
      DS_READY=$(kubectl_cmd get ds -n "$PDNS_NS" pdns-auth -o jsonpath='{.status.numberReady}' 2>/dev/null)
      DS_DESIRED=$(kubectl_cmd get ds -n "$PDNS_NS" pdns-auth -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)
      if [[ "$DS_READY" == "$DS_DESIRED" && -n "$DS_READY" && "$DS_READY" -gt 0 ]]; then
        check_pass "DaemonSet pdns-auth: $DS_READY/$DS_DESIRED ready" "$(elapsed_ms "$P1_START")"
      else
        check_fail "DaemonSet pdns-auth: $DS_READY/$DS_DESIRED ready" "$(elapsed_ms "$P1_START")"
      fi

      # Service has VIP
      SVC_IP=$(kubectl_cmd get svc -n "$PDNS_NS" pdns-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
      if [[ "$SVC_IP" == "$VIP" ]]; then
        check_pass "Service pdns-lb: EXTERNAL-IP=$SVC_IP"
      else
        check_fail "Service pdns-lb: EXTERNAL-IP=$SVC_IP (expected $VIP)"
      fi

      # ArgoCD app healthy
      ARGO_HEALTH=$(kubectl_cmd -n argocd get app pdns -o jsonpath='{.status.health.status}' 2>/dev/null)
      ARGO_SYNC=$(kubectl_cmd -n argocd get app pdns -o jsonpath='{.status.sync.status}' 2>/dev/null)
      if [[ "$ARGO_HEALTH" == "Healthy" && "$ARGO_SYNC" == "Synced" ]]; then
        check_pass "ArgoCD app pdns: $ARGO_SYNC/$ARGO_HEALTH"
      else
        check_fail "ArgoCD app pdns: $ARGO_SYNC/$ARGO_HEALTH"
      fi

      # ── Phase 2: Schema Bootstrap ────────────────────────────────
      phase_header 2 "Schema Bootstrap" 30

      P2_START=$(time_ms)

      # Schema job completed
      JOB_STATUS=$(kubectl_cmd get job -n "$PDNS_NS" pdns-schema-bootstrap -o jsonpath='{.status.succeeded}' 2>/dev/null)
      if [[ "$JOB_STATUS" == "1" ]]; then
        check_pass "Job pdns-schema-bootstrap: completed" "$(elapsed_ms "$P2_START")"
      else
        check_fail "Job pdns-schema-bootstrap: not completed (succeeded=$JOB_STATUS)" "$(elapsed_ms "$P2_START")"
      fi

      # TSIG job completed
      TSIG_STATUS=$(kubectl_cmd get job -n "$PDNS_NS" pdns-tsig-bootstrap -o jsonpath='{.status.succeeded}' 2>/dev/null)
      if [[ "$TSIG_STATUS" == "1" ]]; then
        check_pass "Job pdns-tsig-bootstrap: completed"
      else
        check_fail "Job pdns-tsig-bootstrap: not completed (succeeded=$TSIG_STATUS)"
      fi

      # ── Phase 3: DNS Resolution (VIP) ───────────────────────────
      phase_header 3 "DNS Resolution (VIP)" 30

      P3_START=$(time_ms)
      for domain in "''${DOMAINS[@]}"; do
        SOA=$(dig @"$VIP" "$domain" SOA +short +time=5 +tries=2 2>/dev/null)
        if echo "$SOA" | grep -q "ns1\.$domain"; then
          check_pass "dig @$VIP $domain SOA: OK" "$(elapsed_ms "$P3_START")"
        else
          check_fail "dig @$VIP $domain SOA: $SOA" "$(elapsed_ms "$P3_START")"
        fi
        P3_START=$(time_ms)
      done

      # ── Phase 4: DNS Resolution (per-node) ──────────────────────
      phase_header 4 "DNS Resolution (per-node)" 60

      for ip in "''${NODE_IPS[@]}"; do
        P4_START=$(time_ms)
        SOA=$(dig @"$ip" "''${DOMAINS[0]}" SOA +short +time=5 +tries=2 2>/dev/null)
        if echo "$SOA" | grep -q "ns1\.''${DOMAINS[0]}"; then
          check_pass "dig @$ip ''${DOMAINS[0]} SOA: OK" "$(elapsed_ms "$P4_START")"
        else
          check_fail "dig @$ip ''${DOMAINS[0]} SOA: $SOA" "$(elapsed_ms "$P4_START")"
        fi
      done

      # ── Phase 5: RFC2136 Dynamic Update (TSIG) ──────────────────
      phase_header 5 "RFC2136 Dynamic Update" 30

      P5_START=$(time_ms)

      # Read TSIG key from cluster Secret
      TSIG_KEY=$(kubectl_cmd -n "$PDNS_NS" get secret pdns-credentials \
        -o jsonpath='{.data.tsig-secret}' 2>/dev/null | base64 -d 2>/dev/null)

      if [[ -z "$TSIG_KEY" ]]; then
        check_fail "Could not read TSIG key from pdns-credentials"
      else
        TEST_DOMAIN="_pdns-test.''${DOMAINS[0]}"

        # Add a TXT record
        nsupdate -y "${constants.pdns.tsigAlgorithm}:${constants.pdns.tsigKeyName}:$TSIG_KEY" <<NSUPDATE_EOF 2>/dev/null
server $VIP
update add $TEST_DOMAIN 60 TXT "smoke-test-ok"
send
NSUPDATE_EOF
        ADD_RC=$?

        if [[ $ADD_RC -eq 0 ]]; then
          # Verify the TXT record (allow time for PG write + zone reload)
          sleep 5
          TXT_VAL=$(dig @"$VIP" "$TEST_DOMAIN" TXT +short +time=5 2>/dev/null)
          if echo "$TXT_VAL" | grep -q "smoke-test-ok"; then
            check_pass "RFC2136 add + verify TXT: OK" "$(elapsed_ms "$P5_START")"
          else
            check_fail "RFC2136 verify TXT: got $TXT_VAL" "$(elapsed_ms "$P5_START")"
          fi

          # Cleanup: delete the test record
          if nsupdate -y "${constants.pdns.tsigAlgorithm}:${constants.pdns.tsigKeyName}:$TSIG_KEY" <<NSUPDATE_DEL_EOF 2>/dev/null; then
server $VIP
update delete $TEST_DOMAIN TXT
send
NSUPDATE_DEL_EOF
            check_pass "RFC2136 delete TXT: OK"
          else
            check_fail "RFC2136 delete TXT: failed"
          fi
        else
          check_fail "RFC2136 add TXT: nsupdate failed (rc=$ADD_RC)" "$(elapsed_ms "$P5_START")"
        fi
      fi

      # ── Phase 6: cert-manager Integration ────────────────────────
      phase_header 6 "cert-manager Integration" 30

      P6_START=$(time_ms)
      ISSUER_READY=$(kubectl_cmd get clusterissuer letsencrypt-prod-dns01 \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
      if [[ "$ISSUER_READY" == "True" ]]; then
        check_pass "ClusterIssuer letsencrypt-prod-dns01: Ready" "$(elapsed_ms "$P6_START")"
      else
        # May not be Ready if ACME registration hasn't completed (no internet)
        warn "  ClusterIssuer letsencrypt-prod-dns01: status=$ISSUER_READY (may need internet)"
        check_fail "ClusterIssuer letsencrypt-prod-dns01: not Ready ($ISSUER_READY)" "$(elapsed_ms "$P6_START")"
      fi

      # ── Phase 7: nginx TLS ──────────────────────────────────────
      phase_header 7 "nginx TLS" 30

      P7_START=$(time_ms)

      # Certificate CR exists
      CERT_EXISTS=$(kubectl_cmd get certificate -n nginx nginx-le-tls -o name 2>/dev/null)
      if [[ -n "$CERT_EXISTS" ]]; then
        check_pass "Certificate nginx-le-tls: exists" "$(elapsed_ms "$P7_START")"
      else
        check_fail "Certificate nginx-le-tls: not found" "$(elapsed_ms "$P7_START")"
      fi

      # Ingress has all hosts
      INGRESS_HOSTS=$(kubectl_cmd get ingress -n nginx nginx -o jsonpath='{.spec.rules[*].host}' 2>/dev/null)
      for domain in "${constants.nginx.hostName}" "''${DOMAINS[@]}"; do
        if echo "$INGRESS_HOSTS" | grep -q "$domain"; then
          check_pass "Ingress host $domain: present"
        else
          check_fail "Ingress host $domain: missing from Ingress"
        fi
      done

      # ── Summary ──────────────────────────────────────────────────
      TOTAL_MS=$(elapsed_ms "$TOTAL_START")
      echo ""
      bold "========================================="
      bold "  PowerDNS Smoke Test Summary"
      bold "========================================="
      success "  PASS: $PASS_COUNT"
      if [[ $FAIL_COUNT -gt 0 ]]; then
        error "  FAIL: $FAIL_COUNT"
      else
        echo "  FAIL: 0"
      fi
      echo "  Total time: $(format_ms "$TOTAL_MS")"
      bold "========================================="

      if [[ $FAIL_COUNT -gt 0 ]]; then
        exit 1
      fi
    '';
  };
}
