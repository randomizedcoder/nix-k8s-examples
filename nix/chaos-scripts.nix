# nix/chaos-scripts.nix
#
# Chaos / failover verification tool.
#
# Loops through the cluster's 4 MicroVMs, killing one at a time, and
# measures how long each of the 4 HA databases (PostgreSQL via CNPG,
# TiDB, ClickHouse, FoundationDB) takes to start accepting transactions
# again after the kill. Brings the VM back and repeats.
#
# Intended use: a repeatable confidence test that catches regressions in
# DB failover behaviour.
#
# See README "Chaos / Failover Test" section for usage.
#
{ pkgs }:
let
  constants = import ./constants.nix;
in
{
  chaosFailover = pkgs.writeShellApplication {
    name = "k8s-chaos-failover";
    runtimeInputs = with pkgs; [
      kubectl
      postgresql          # psql
      mariadb             # mysql client for TiDB
      clickhouse          # clickhouse-client
      bc                  # float math for recovery timestamps
      gawk
      coreutils
      procps
      nix
      gnused
      sshpass
      openssh
    ];
    text = ''
      set -uo pipefail

      # ─── Defaults (from constants.nix) ───────────────────────────────
      ROUNDS=${toString constants.chaos.defaultRounds}
      INTERVAL=${toString constants.chaos.defaultIntervalSec}
      POST_ROUND_WAIT=${toString constants.chaos.defaultPostRoundWait}
      WARMUP=${toString constants.chaos.defaultWarmupSec}
      LOG_DIR="${constants.chaos.defaultLogDir}"
      NODES="cp0,cp1,cp2,w3"
      SKIP_DBS=""

      CP0_IP="${constants.network.ipv4.cp0}"
      PG_PORT="${toString constants.postgres.nodePortRw}"
      TIDB_PORT="${toString constants.tidb.nodePort}"
      CH_PORT_NATIVE="${toString constants.clickhouse.nodePortNative}"
      SSH_PASS="${constants.ssh.password}"

      usage() {
        cat <<EOF
Usage: k8s-chaos-failover [OPTIONS]

Kills one K8s MicroVM at a time, measures DB recovery, repeats.

Options:
  --rounds=N             Number of rounds (default: $ROUNDS)
  --interval=SEC         Minimum seconds between kills (default: $INTERVAL)
  --post-round-wait=SEC  Seconds to wait after node rejoins (default: $POST_ROUND_WAIT)
  --warmup=SEC           Seconds to let workloads stabilise (default: $WARMUP)
  --nodes=LIST           Comma-separated nodes (default: $NODES)
  --skip-dbs=LIST        Comma-separated DBs to skip: pg,tidb,clickhouse,fdb
  --log-dir=DIR          Output directory (default: $LOG_DIR)
  -h, --help             Show this help

Requires: cluster running, kubectl reachable via ssh to cp0.
EOF
      }

      # ─── Parse args ──────────────────────────────────────────────────
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --rounds=*)           ROUNDS="''${1#*=}"; shift ;;
          --interval=*)         INTERVAL="''${1#*=}"; shift ;;
          --post-round-wait=*)  POST_ROUND_WAIT="''${1#*=}"; shift ;;
          --warmup=*)           WARMUP="''${1#*=}"; shift ;;
          --nodes=*)            NODES="''${1#*=}"; shift ;;
          --skip-dbs=*)         SKIP_DBS="''${1#*=}"; shift ;;
          --log-dir=*)          LOG_DIR="''${1#*=}"; shift ;;
          -h|--help)            usage; exit 0 ;;
          *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
        esac
      done

      mkdir -p "$LOG_DIR"
      SUMMARY="$LOG_DIR/summary.tsv"
      EVENTS="$LOG_DIR/events.log"
      : > "$SUMMARY"
      : > "$EVENTS"
      printf "round\tnode\tdb\tpg_primary_pre\trecover_sec\trejoin_sec\n" > "$SUMMARY"

      log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$EVENTS"; }

      # ─── kubectl via cp0 over SSH ─────────────────────────────────────
      # Avoid requiring a host kubeconfig. Runs kubectl on cp0 with its
      # in-VM admin kubeconfig.
      kctl() {
        sshpass -p "$SSH_PASS" ssh \
          -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          -o LogLevel=ERROR \
          "root@$CP0_IP" \
          "KUBECONFIG=/var/lib/kubernetes/pki/admin-kubeconfig kubectl $*"
      }

      # ─── Pre-build stop-one/start-one so hot loop is fast ────────────
      log "Pre-building k8s-vm-stop-one and k8s-vm-start-one..."
      STOP_BIN="$(nix build --no-link --print-out-paths .#k8s-vm-stop-one)/bin/k8s-vm-stop-one"
      START_BIN="$(nix build --no-link --print-out-paths .#k8s-vm-start-one)/bin/k8s-vm-start-one"

      # ─── Check DB skip list ──────────────────────────────────────────
      skip_db() {
        case ",$SKIP_DBS," in *",$1,"*) return 0 ;; *) return 1 ;; esac
      }

      DBS=()
      for db in pg tidb clickhouse fdb; do
        if ! skip_db "$db"; then DBS+=("$db"); fi
      done
      log "DBs under test: ''${DBS[*]}"

      # ─── Resolve PG password once ────────────────────────────────────
      PG_PASS=""
      if [[ " ''${DBS[*]} " == *" pg "* ]]; then
        PG_PASS="$(kctl -n postgres get secret pg-app -o jsonpath='{.data.password}' | base64 -d)"
        if [[ -z "$PG_PASS" ]]; then
          log "ERROR: could not read pg-app secret" >&2
          exit 1
        fi
      fi

      # ─── Ensure per-DB chaos tables exist ────────────────────────────
      ensure_pg() {
        PGPASSWORD="$PG_PASS" psql -h "$CP0_IP" -p "$PG_PORT" -U app -d app -w \
          -c "CREATE TABLE IF NOT EXISTS chaos (ts timestamptz DEFAULT now());" >/dev/null
      }
      ensure_tidb() {
        mysql -h "$CP0_IP" -P "$TIDB_PORT" -u root --connect-timeout=5 \
          -e "CREATE DATABASE IF NOT EXISTS chaos;
              CREATE TABLE IF NOT EXISTS chaos.t (ts TIMESTAMP(6) DEFAULT CURRENT_TIMESTAMP(6));" >/dev/null
      }
      ensure_clickhouse() {
        clickhouse-client --host "$CP0_IP" --port "$CH_PORT_NATIVE" \
          -q "CREATE DATABASE IF NOT EXISTS chaos;
              CREATE TABLE IF NOT EXISTS chaos.t (ts DateTime64(6) DEFAULT now64()) ENGINE = MergeTree ORDER BY ts;" >/dev/null
      }
      ensure_fdb() {
        # FDB is schemaless; writemode toggle is per-session. No setup.
        :
      }

      for db in "''${DBS[@]}"; do
        log "ensuring chaos table for $db..."
        case "$db" in
          pg)          ensure_pg          || { log "ERROR: pg not reachable"; exit 1; } ;;
          tidb)        ensure_tidb        || { log "ERROR: tidb not reachable"; exit 1; } ;;
          clickhouse)  ensure_clickhouse  || { log "ERROR: clickhouse not reachable"; exit 1; } ;;
          fdb)         ensure_fdb ;;
        esac
      done

      # ─── Pick a live FDB pod ─────────────────────────────────────────
      # Re-resolve each iteration in case the previous pick was on a
      # node we're about to kill (or just killed).
      pick_fdb_pod() {
        kctl -n fdb get pods -l app=fdb \
          --field-selector=status.phase=Running \
          -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
      }

      # ─── Workload loops (one subshell per DB) ────────────────────────
      run_workload_pg() {
        while true; do
          ts="$(date +%s.%N)"
          if out=$(PGPASSWORD="$PG_PASS" psql -h "$CP0_IP" -p "$PG_PORT" \
                     -U app -d app -w -tA --set ON_ERROR_STOP=1 \
                     -c "INSERT INTO chaos DEFAULT VALUES; SELECT count(*) FROM chaos;" 2>&1); then
            echo "$ts OK"
          else
            echo "$ts FAIL ''${out//$'\n'/ }"
          fi
          sleep 0.5
        done
      }

      run_workload_tidb() {
        while true; do
          ts="$(date +%s.%N)"
          if out=$(mysql -h "$CP0_IP" -P "$TIDB_PORT" -u root \
                     --connect-timeout=3 \
                     -e "INSERT INTO chaos.t VALUES(NOW(6)); SELECT COUNT(*) FROM chaos.t;" 2>&1); then
            echo "$ts OK"
          else
            echo "$ts FAIL ''${out//$'\n'/ }"
          fi
          sleep 0.5
        done
      }

      run_workload_clickhouse() {
        while true; do
          ts="$(date +%s.%N)"
          if out=$(clickhouse-client --host "$CP0_IP" --port "$CH_PORT_NATIVE" \
                     --connect_timeout 3 --send_timeout 3 --receive_timeout 3 \
                     -q "INSERT INTO chaos.t VALUES(now64()); SELECT count() FROM chaos.t;" 2>&1); then
            echo "$ts OK"
          else
            echo "$ts FAIL ''${out//$'\n'/ }"
          fi
          sleep 0.5
        done
      }

      run_workload_fdb() {
        while true; do
          ts="$(date +%s.%N)"
          pod="$(pick_fdb_pod)"
          if [[ -z "$pod" ]]; then
            echo "$ts FAIL no_live_fdb_pod"
          else
            if out=$(kctl -n fdb exec "$pod" -- \
                       fdbcli --exec "writemode on; set chaos:$ts 1; get chaos:$ts" 2>&1); then
              echo "$ts OK"
            else
              echo "$ts FAIL ''${out//$'\n'/ }"
            fi
          fi
          sleep 0.5
        done
      }

      # ─── Start workloads ─────────────────────────────────────────────
      declare -A WPIDS
      for db in "''${DBS[@]}"; do
        run_workload_"$db" > "$LOG_DIR/$db.log" 2>&1 &
        WPIDS[$db]=$!
        log "workload $db started (pid=''${WPIDS[$db]})"
      done

      # ─── Cleanup: stop workloads + best-effort restart any dead VM ───
      cleanup() {
        log "=== Cleanup ==="
        for db in "''${!WPIDS[@]}"; do
          kill "''${WPIDS[$db]}" 2>/dev/null || true
        done
        wait 2>/dev/null || true
        for n in cp0 cp1 cp2 w3; do
          if ! pgrep -x "k8s-$n" >/dev/null; then
            log "  $n is down, attempting restart..."
            "$START_BIN" --node="$n" || log "  (start $n failed)"
          fi
        done
      }
      trap cleanup EXIT INT TERM

      log "=== Warmup ($WARMUP s) ==="
      sleep "$WARMUP"

      # ─── Wait helpers ────────────────────────────────────────────────
      wait_readyz() {
        local deadline=$(( SECONDS + $1 ))
        while (( SECONDS < deadline )); do
          if kctl get --raw /readyz 2>/dev/null | grep -q '^ok$'; then return 0; fi
          sleep 2
        done
        return 1
      }
      wait_node_ready() {
        local node="$1"
        local deadline=$(( SECONDS + $2 ))
        while (( SECONDS < deadline )); do
          if kctl get node "k8s-$node" \
               -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null \
             | grep -q '^True$'; then
            return 0
          fi
          sleep 2
        done
        return 1
      }

      # ─── Parse node list ─────────────────────────────────────────────
      IFS=',' read -ra NODE_LIST <<< "$NODES"

      # ─── Main loop ───────────────────────────────────────────────────
      START_WALL="$(date +%s)"
      for r in $(seq 1 "$ROUNDS"); do
        for node in "''${NODE_LIST[@]}"; do
          log "── Round $r / $ROUNDS — node $node ──"

          log "  pre-kill health gate..."
          if ! wait_readyz 120; then log "  WARN: /readyz not ok, skipping round $r node $node"; continue; fi
          if ! wait_node_ready "$node" 60; then
            log "  WARN: $node not Ready pre-kill, skipping"; continue
          fi

          PG_PRIMARY="unknown"
          if [[ " ''${DBS[*]} " == *" pg "* ]]; then
            PG_PRIMARY="$(kctl -n postgres get cluster pg -o jsonpath='{.status.currentPrimary}' 2>/dev/null || echo unknown)"
          fi
          log "  pg primary (pre-kill): $PG_PRIMARY"

          T0="$(date +%s.%N)"
          log "  KILL $node @ $T0"
          "$STOP_BIN" --node="$node"

          log "  START $node"
          "$START_BIN" --node="$node"

          log "  waiting for $node Ready (timeout 300s)..."
          if wait_node_ready "$node" 300; then
            T_REJOIN="$(date +%s.%N)"
            REJOIN_DELTA="$(echo "$T_REJOIN - $T0" | bc -l)"
            log "  $node Ready after $REJOIN_DELTA s"
          else
            T_REJOIN="$T0"
            REJOIN_DELTA="-1"
            log "  WARN: $node did not become Ready within 300s"
          fi

          # Per-DB recovery: first OK in log with ts > T0
          for db in "''${DBS[@]}"; do
            logf="$LOG_DIR/$db.log"
            t_rec="$(awk -v t0="$T0" '$2=="OK" && ($1+0) > (t0+0) {print $1; exit}' "$logf")"
            if [[ -n "$t_rec" ]]; then
              delta="$(echo "$t_rec - $T0" | bc -l)"
            else
              delta="-1"
            fi
            printf "%d\t%s\t%s\t%s\t%.3f\t%.3f\n" \
              "$r" "$node" "$db" "$PG_PRIMARY" "$delta" "$REJOIN_DELTA" >> "$SUMMARY"
            log "    $db recovered in $delta s"
          done

          log "  post-round wait: $POST_ROUND_WAIT s"
          sleep "$POST_ROUND_WAIT"

          # Honour --interval: pad if round was quicker than INTERVAL
          ROUND_ELAPSED=$(( $(date +%s) - START_WALL ))
          EXPECTED=$(( (r - 1) * ''${#NODE_LIST[@]} * INTERVAL ))
          if (( ROUND_ELAPSED < EXPECTED )); then
            sleep $(( EXPECTED - ROUND_ELAPSED ))
          fi
        done
      done

      # ─── Summary ─────────────────────────────────────────────────────
      log "=== Summary ==="
      echo
      column -t -s $'\t' "$SUMMARY"
      echo
      echo "Per-DB recovery stats (seconds):"
      awk -F'\t' 'NR>1 && $5>=0 {
        k=$3; n[k]++; sum[k]+=$5;
        if (min[k]=="" || $5<min[k]) min[k]=$5;
        if (max[k]=="" || $5>max[k]) max[k]=$5;
      }
      END {
        printf "  %-12s  %6s  %8s  %8s  %8s\n", "db", "runs", "min", "mean", "max";
        for (k in n) printf "  %-12s  %6d  %8.3f  %8.3f  %8.3f\n", k, n[k], min[k], sum[k]/n[k], max[k];
      }' "$SUMMARY"

      log "logs: $LOG_DIR/"
    '';
  };
}
