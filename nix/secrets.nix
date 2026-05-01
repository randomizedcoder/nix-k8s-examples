# nix/secrets.nix
#
# Reads pre-generated secrets from ./secrets/ and produces K8s Secret
# YAML manifests that the bootstrap module applies at first boot.
#
# If ./secrets/ does not exist, returns { k8sSecrets = null; } so the
# cluster still builds — Secrets just keep their
# __BOOTSTRAPPED_OUT_OF_BAND__ placeholders.
#
# All Secret manifests are emitted as JSON (not YAML) because some
# values contain shell-hostile characters (bcrypt `$2y$...`). K8s
# kubectl apply handles JSON natively.
#
# See docs/secrets.md for the full design.
#
{ pkgs, lib }:
let
  secretsDir = ../secrets;
  hasSecrets = builtins.pathExists secretsDir;

  constants = import ./constants.nix;
  o  = constants.observability;
  ch = o.clickhouse;
  r  = constants.registry;
in
if !hasSecrets then { k8sSecrets = null; sshPubKey = null; }
else
let
  # ─── Read raw secrets ────────────────────────────────────────────────
  read = name: lib.trim (builtins.readFile (secretsDir + "/${name}"));

  anubisKey            = read "anubis-ed25519-key";
  matrixMacaroon       = read "matrix-macaroon";
  matrixForm           = read "matrix-form";
  matrixRegistration   = read "matrix-registration";
  matrixHookshotAs     = read "matrix-hookshot-as";
  matrixHookshotHs     = read "matrix-hookshot-hs";
  matrixMaubotAs       = read "matrix-maubot-as";
  matrixMaubotHs       = read "matrix-maubot-hs";
  matrixMaubotUnshared = read "matrix-maubot-unshared";
  matrixMaubotAdmin    = read "matrix-maubot-admin";
  matrixDiscordAs      = read "matrix-discord-as";
  matrixDiscordHs      = read "matrix-discord-hs";
  chOtelPassword       = read "ch-otel-password";
  chHyperdxPassword    = read "ch-hyperdx-password";
  registryPushPassword = read "registry-push-password";

  # SSH public key for MicroVM authorized_keys
  sshPubKeyFile = secretsDir + "/ssh-ed25519.pub";
  sshPubKey = if builtins.pathExists sshPubKeyFile
    then lib.trim (builtins.readFile sshPubKeyFile)
    else null;

  # ─── Build K8s Secret manifests (JSON) ──────────────────────────────
  # One runCommand that derives bcrypt hashes / JSON configs and
  # assembles all 6 Secret manifests. Uses jq throughout so values
  # with $, quotes, or newlines are never shell-interpreted.
  k8sSecrets = pkgs.runCommand "k8s-secrets" {
    nativeBuildInputs = with pkgs; [ apacheHttpd jq coreutils ];

    # Raw secrets
    ANUBIS_KEY             = anubisKey;
    MATRIX_MACAROON        = matrixMacaroon;
    MATRIX_FORM            = matrixForm;
    MATRIX_REGISTRATION    = matrixRegistration;
    MATRIX_HOOKSHOT_AS     = matrixHookshotAs;
    MATRIX_HOOKSHOT_HS     = matrixHookshotHs;
    MATRIX_MAUBOT_AS       = matrixMaubotAs;
    MATRIX_MAUBOT_HS       = matrixMaubotHs;
    MATRIX_MAUBOT_UNSHARED = matrixMaubotUnshared;
    MATRIX_MAUBOT_ADMIN    = matrixMaubotAdmin;
    MATRIX_DISCORD_AS      = matrixDiscordAs;
    MATRIX_DISCORD_HS      = matrixDiscordHs;
    CH_OTEL_PASS           = chOtelPassword;
    CH_HYPERDX_PASS        = chHyperdxPassword;
    REGISTRY_PASS          = registryPushPassword;

    # Constants
    CH_USER_WRITER  = ch.user;
    CH_USER_READER  = ch.uiUser;
    CH_DATABASE     = ch.database;
    REGISTRY_USER   = r.pushUser;
    OBS_NS          = o.namespace;
    REG_NS          = r.namespace;
  } ''
    mkdir -p $out

    # ── Derive bcrypt hashes ──────────────────────────────────────────
    MAUBOT_BCRYPT="$(htpasswd -nbB admin "$MATRIX_MAUBOT_ADMIN" | cut -d: -f2)"
    HTPASSWD_LINE="$(htpasswd -nbB "$REGISTRY_USER" "$REGISTRY_PASS")"

    # ── Derive ClickStack JSON configs ────────────────────────────────
    CONNECTIONS_JSON="$(jq -n --compact-output \
      --arg host "http://clickhouse.clickhouse.svc.cluster.local:8123" \
      --arg user "$CH_USER_READER" \
      --arg pass "$CH_HYPERDX_PASS" \
      '[{name:"ch4", host:$host, port:8123, username:$user, password:$pass}]')"

    SOURCES_JSON="$(jq -n --compact-output \
      --arg conn "ch4" \
      --arg db   "$CH_DATABASE" \
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

    # ── Homeserver secrets YAML (embedded as a string value) ──────────
    # PG password is a placeholder — bootstrap patches it live.
    HOMESERVER_YAML="$(printf '%s\n' \
      "macaroon_secret_key: \"$MATRIX_MACAROON\"" \
      "form_secret: \"$MATRIX_FORM\"" \
      "registration_shared_secret: \"$MATRIX_REGISTRATION\"" \
      "database:" \
      "  name: psycopg2" \
      "  args:" \
      "    user: app" \
      "    password: \"__PG_PASSWORD_INJECTED_AT_BOOT__\"" \
      "    database: synapse" \
      "    host: pg-rw.postgres.svc.cluster.local" \
      "    port: 5432" \
      "    cp_min: 5" \
      "    cp_max: 10")"

    # ── 1. anubis-secrets (ns: nginx) ─────────────────────────────────
    jq -n \
      --arg key "$ANUBIS_KEY" \
      '{apiVersion:"v1", kind:"Secret",
        metadata:{name:"anubis-secrets", namespace:"nginx"},
        stringData:{ed25519_private_key_hex:$key}}' \
      > $out/anubis-secrets.json

    # ── 2. matrix-secrets (ns: matrix) ────────────────────────────────
    jq -n \
      --arg hs_yaml     "$HOMESERVER_YAML" \
      --arg reg         "$MATRIX_REGISTRATION" \
      --arg hookshot_as "$MATRIX_HOOKSHOT_AS" \
      --arg hookshot_hs "$MATRIX_HOOKSHOT_HS" \
      --arg maubot_as   "$MATRIX_MAUBOT_AS" \
      --arg maubot_hs   "$MATRIX_MAUBOT_HS" \
      --arg maubot_un   "$MATRIX_MAUBOT_UNSHARED" \
      --arg maubot_bc   "$MAUBOT_BCRYPT" \
      --arg discord_as  "$MATRIX_DISCORD_AS" \
      --arg discord_hs  "$MATRIX_DISCORD_HS" \
      '{apiVersion:"v1", kind:"Secret",
        metadata:{name:"matrix-secrets", namespace:"matrix"},
        stringData:{
          "homeserver.secrets.yaml":$hs_yaml,
          registration_shared_secret:$reg,
          pg_app_password:"__PG_PASSWORD_INJECTED_AT_BOOT__",
          hookshot_as_token:$hookshot_as,
          hookshot_hs_token:$hookshot_hs,
          maubot_as_token:$maubot_as,
          maubot_hs_token:$maubot_hs,
          maubot_unshared_secret:$maubot_un,
          maubot_admin_bcrypt:$maubot_bc,
          mautrix_discord_as_token:$discord_as,
          mautrix_discord_hs_token:$discord_hs}}' \
      > $out/matrix-secrets.json

    # ── 3. otel-ch-credentials (ns: observability) ────────────────────
    # Includes both writer (otel) and reader (hyperdx) credentials so
    # the ch-users Job can read both from one Secret.
    jq -n \
      --arg user "$CH_USER_WRITER" \
      --arg pass "$CH_OTEL_PASS" \
      --arg huser "$CH_USER_READER" \
      --arg hpass "$CH_HYPERDX_PASS" \
      --arg ns   "$OBS_NS" \
      '{apiVersion:"v1", kind:"Secret",
        metadata:{name:"otel-ch-credentials", namespace:$ns},
        stringData:{CLICKHOUSE_USER:$user, CLICKHOUSE_PASSWORD:$pass,
                    HYPERDX_USER:$huser, HYPERDX_PASSWORD:$hpass}}' \
      > $out/otel-ch-credentials.json

    # ── 4. clickstack-hyperdx-config (ns: observability) ──────────────
    jq -n \
      --arg conn "$CONNECTIONS_JSON" \
      --arg src  "$SOURCES_JSON" \
      --arg ns   "$OBS_NS" \
      '{apiVersion:"v1", kind:"Secret",
        metadata:{name:"clickstack-hyperdx-config", namespace:$ns},
        stringData:{"connections.json":$conn, "sources.json":$src}}' \
      > $out/clickstack-hyperdx-config.json

    # ── 5. registry-htpasswd (ns: registry) ───────────────────────────
    # Includes the raw push password alongside the bcrypt htpasswd line
    # so the k8s-registry-push service can authenticate via skopeo.
    jq -n \
      --arg ht "$HTPASSWD_LINE" \
      --arg pw "$REGISTRY_PASS" \
      --arg ns "$REG_NS" \
      '{apiVersion:"v1", kind:"Secret",
        metadata:{name:"registry-htpasswd", namespace:$ns},
        stringData:{htpasswd:$ht, "push-password":$pw}}' \
      > $out/registry-htpasswd.json

    echo "Generated $(ls $out/*.json | wc -l) Secret manifests"
  '';

in
{
  inherit k8sSecrets sshPubKey;
}
