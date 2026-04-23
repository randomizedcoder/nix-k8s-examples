# nix/observability-scripts.nix
#
# Operator helpers for the observability stack. Phase-1 only needs
# one: a bootstrap script that provisions the two CH users
# (`otel` writer, `hyperdx` reader) and populates the two Secrets
# that the collector DS (PR 2) and HyperDX UI (PR 4) consume.
#
# Mirrors nix/matrix-scripts.nix:94-244 for consistency.
#
{ pkgs }:
let
  constants = import ./constants.nix;
  o = constants.observability;
  ch = o.clickhouse;
in
{
  # One-shot provisioning of the observability stack's out-of-band
  # creds. Generates random CH passwords for `otel` (writer) and
  # `hyperdx` (reader), runs the CREATE USER + GRANT DDL `ON CLUSTER
  # ch4` via cp0's kubectl exec into a CH pod, and overwrites the
  # two placeholder Secrets the gitops pipeline emitted.
  #
  #   nix run .#k8s-observability-bootstrap-secrets
  #
  # Idempotent: re-running refuses to touch existing Secrets unless
  # `--force` is passed. The DDL itself is `IF NOT EXISTS` and safe
  # to re-run on its own.
  bootstrapSecrets = pkgs.writeShellApplication {
    name = "k8s-observability-bootstrap-secrets";
    runtimeInputs = with pkgs; [ sshpass openssh coreutils openssl jq ];
    text = ''
      set -euo pipefail

      FORCE="no"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --force) FORCE="yes"; shift ;;
          *) echo "Unknown arg: $1" >&2; exit 2 ;;
        esac
      done

      CP0_IP="${constants.network.ipv4.cp0}"
      NS="${o.namespace}"
      CH_NS="clickhouse"
      CH_POD="clickhouse-0"
      CH_CLUSTER="${ch.cluster}"
      CH_DB="${ch.database}"
      CH_USER_WRITER="${ch.user}"
      CH_USER_READER="${ch.uiUser}"

      ssh_exec() {
        sshpass -p ${constants.ssh.password} ssh \
          -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          -o LogLevel=ERROR \
          root@"$CP0_IP" \
          "export KUBECONFIG=/var/lib/kubernetes/pki/admin-kubeconfig; $*"
      }

      # Refuse to overwrite live Secrets unless the operator opted in.
      if [[ "$FORCE" != "yes" ]]; then
        EXISTING=""
        if ssh_exec "kubectl -n $NS get secret otel-ch-credentials -o jsonpath='{.data.CLICKHOUSE_PASSWORD}' 2>/dev/null" | grep -q .; then
          EXISTING="otel-ch-credentials"
        fi
        if ssh_exec "kubectl -n $NS get secret clickstack-hyperdx-config -o jsonpath='{.data.connections\\.json}' 2>/dev/null" | base64 -d 2>/dev/null | jq -e 'length > 0' >/dev/null 2>&1; then
          EXISTING="''${EXISTING:+$EXISTING, }clickstack-hyperdx-config"
        fi
        if [[ -n "$EXISTING" ]]; then
          echo "Secret(s) already populated: $EXISTING. Pass --force to overwrite." >&2
          exit 1
        fi
      fi

      OTEL_PASS="$(openssl rand -hex 32)"
      HYPERDX_PASS="$(openssl rand -hex 32)"

      # CREATE USER + GRANT via the cluster-wide DDL fan-out. The
      # `ON CLUSTER` form applies to every replica in ch4.
      DDL=$(cat <<EOF
CREATE USER IF NOT EXISTS $CH_USER_WRITER ON CLUSTER $CH_CLUSTER IDENTIFIED BY '$OTEL_PASS';
ALTER  USER $CH_USER_WRITER ON CLUSTER $CH_CLUSTER IDENTIFIED BY '$OTEL_PASS';
GRANT  INSERT ON $CH_DB.* TO $CH_USER_WRITER ON CLUSTER $CH_CLUSTER;
GRANT  SELECT ON $CH_DB.* TO $CH_USER_WRITER ON CLUSTER $CH_CLUSTER;

CREATE USER IF NOT EXISTS $CH_USER_READER ON CLUSTER $CH_CLUSTER IDENTIFIED BY '$HYPERDX_PASS';
ALTER  USER $CH_USER_READER ON CLUSTER $CH_CLUSTER IDENTIFIED BY '$HYPERDX_PASS';
GRANT  SELECT ON $CH_DB.* TO $CH_USER_READER ON CLUSTER $CH_CLUSTER;
EOF
)

      # Pipe DDL into clickhouse-client running inside the CH pod.
      # base64 avoids shell-quoting pain across two SSH hops.
      DDL_B64="$(printf '%s' "$DDL" | base64 -w0)"
      ssh_exec "echo $DDL_B64 | base64 -d | kubectl -n $CH_NS exec -i $CH_POD -- clickhouse-client --multiquery"

      # ── otel-ch-credentials: consumed by the collector DS via envFrom.
      ssh_exec "kubectl -n $NS create secret generic otel-ch-credentials \
        --from-literal=CLICKHOUSE_USER='$CH_USER_WRITER' \
        --from-literal=CLICKHOUSE_PASSWORD='$OTEL_PASS' \
        --dry-run=client -o yaml | kubectl apply -f -"

      # ── clickstack-hyperdx-config: connections.json + sources.json
      # consumed by the HyperDX deployment as DEFAULT_CONNECTIONS /
      # DEFAULT_SOURCES env. Points at the ch4 cluster-wide Service
      # (any replica answers) using the hyperdx read-only user.
      CONN_NAME="ch4"
      CONNECTIONS_JSON="$(jq -n \
        --arg name "$CONN_NAME" \
        --arg host "http://clickhouse.clickhouse.svc.cluster.local:8123" \
        --arg user "$CH_USER_READER" \
        --arg pass "$HYPERDX_PASS" \
        '[{name:$name, host:$host, port:8123, username:$user, password:$pass}]')"

      # Sources: the four signal types the PR 2 collector writes. We
      # point at the *_dist wrappers so the CH router fans queries
      # out across shards. The metric source uses the gauge/sum/
      # histogram triad the exporter emits.
      SOURCES_JSON="$(jq -n \
        --arg conn "$CONN_NAME" \
        --arg db   "$CH_DB" \
        '[
          {kind:"log",   name:"Logs",   connection:$conn,
           from:{databaseName:$db, tableName:"otel_logs_dist"},
           timestampValueExpression:"TimestampTime",
           displayedTimestampValueExpression:"Timestamp",
           implicitColumnExpression:"Body",
           serviceNameExpression:"ServiceName",
           bodyExpression:"Body",
           eventAttributesExpression:"LogAttributes",
           resourceAttributesExpression:"ResourceAttributes",
           defaultTableSelectExpression:"Timestamp,ServiceName,SeverityText,Body",
           severityTextExpression:"SeverityText",
           traceIdExpression:"TraceId",
           spanIdExpression:"SpanId"},
          {kind:"trace", name:"Traces", connection:$conn,
           from:{databaseName:$db, tableName:"otel_traces_dist"},
           timestampValueExpression:"Timestamp",
           displayedTimestampValueExpression:"Timestamp",
           implicitColumnExpression:"SpanName",
           serviceNameExpression:"ServiceName",
           bodyExpression:"SpanName",
           eventAttributesExpression:"SpanAttributes",
           resourceAttributesExpression:"ResourceAttributes",
           defaultTableSelectExpression:"Timestamp,ServiceName,StatusCode,round(Duration/1e6),SpanName",
           traceIdExpression:"TraceId",
           spanIdExpression:"SpanId",
           durationExpression:"Duration",
           durationPrecision:9,
           parentSpanIdExpression:"ParentSpanId",
           spanNameExpression:"SpanName",
           spanKindExpression:"SpanKind",
           statusCodeExpression:"StatusCode",
           statusMessageExpression:"StatusMessage"},
          {kind:"metric", name:"Metrics", connection:$conn,
           from:{databaseName:$db, tableName:""},
           timestampValueExpression:"TimeUnix",
           resourceAttributesExpression:"ResourceAttributes",
           metricTables:{gauge:"otel_metrics_gauge_dist",
                         histogram:"otel_metrics_histogram_dist",
                         sum:"otel_metrics_sum_dist"}}
        ]')"

      TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
      printf '%s' "$CONNECTIONS_JSON" > "$TMP/connections.json"
      printf '%s' "$SOURCES_JSON"     > "$TMP/sources.json"

      sshpass -p ${constants.ssh.password} scp \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "$TMP/connections.json" "$TMP/sources.json" \
        root@"$CP0_IP":/tmp/

      ssh_exec "kubectl -n $NS create secret generic clickstack-hyperdx-config \
        --from-file=connections.json=/tmp/connections.json \
        --from-file=sources.json=/tmp/sources.json \
        --dry-run=client -o yaml | kubectl apply -f -"

      ssh_exec "rm -f /tmp/connections.json /tmp/sources.json"

      # Trigger a collector DS rollout so pods pick up the new Secret
      # (envFrom doesn't auto-reload when a Secret's data changes).
      ssh_exec "kubectl -n $NS rollout restart daemonset/otel-collector-opentelemetry-collector-agent" || \
        echo "(skipping DS rollout — is the collector deployed yet?)" >&2

      # Same for the HyperDX Deployment — DEFAULT_CONNECTIONS is read
      # at process start.
      ssh_exec "kubectl -n $NS rollout restart deployment/clickstack-app" || \
        echo "(skipping clickstack-app rollout — is it deployed yet?)" >&2

      echo ""
      echo "=== observability secrets bootstrapped ==="
      echo "  otel-ch-credentials        user=$CH_USER_WRITER (INSERT on $CH_DB.*)"
      echo "  clickstack-hyperdx-config  user=$CH_USER_READER (SELECT on $CH_DB.*)"
      echo ""
      echo "Open the UI: https://${o.clickstack.host}/"
      echo "(add ${constants.cilium.ingress.vip} ${o.clickstack.host} to /etc/hosts if not already)"
    '';
  };
}
