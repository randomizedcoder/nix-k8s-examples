# nix/matrix-scripts.nix
#
# Operator helpers for the Matrix stack. Kept tiny — one user-registration
# wrapper and one secrets-bootstrap helper. Anything larger (space setup,
# bulk bridging) belongs in a future module.
#
{ pkgs }:
let
  constants = import ./constants.nix;
  m = constants.matrix;
in
{
  # Ad-hoc user registration via Synapse's `register_new_matrix_user`
  # CLI. Uses the cluster's admin NodePort to reach Synapse from the
  # host (no kubectl-exec detour needed).
  #
  #   nix run .#k8s-matrix-register-user -- --username=alice
  #
  # Prompts for password. Reads the registration_shared_secret from the
  # in-cluster `matrix-secrets` Secret via kubectl.
  registerUser = pkgs.writeShellApplication {
    name = "k8s-matrix-register-user";
    runtimeInputs = with pkgs; [ kubectl sshpass openssh coreutils curl jq ];
    text = ''
      set -euo pipefail

      USER=""
      ADMIN="no"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --username=*) USER="''${1#--username=}"; shift ;;
          --admin)      ADMIN="yes"; shift ;;
          *) echo "Usage: k8s-matrix-register-user --username=<name> [--admin]" >&2; exit 2 ;;
        esac
      done
      if [[ -z "$USER" ]]; then
        echo "Usage: k8s-matrix-register-user --username=<name> [--admin]" >&2
        exit 2
      fi

      CP0_IP="${constants.network.ipv4.cp0}"
      ADMIN_URL="http://$CP0_IP:${toString m.synapseAdminNodePort}"

      # Pull the shared secret from the in-cluster Secret via cp0 kubectl.
      SHARED_SECRET="$(sshpass -p ${constants.ssh.password} ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        root@"$CP0_IP" \
        "KUBECONFIG=/var/lib/kubernetes/pki/admin-kubeconfig kubectl -n matrix get secret matrix-secrets -o jsonpath='{.data.registration_shared_secret}'" \
        | base64 -d)"

      if [[ -z "$SHARED_SECRET" ]]; then
        echo "Could not read registration_shared_secret from matrix-secrets" >&2
        echo "Did you create matrix-secrets yet? See docs/matrix.md." >&2
        exit 1
      fi

      read -rsp "Password for $USER: " PASS; echo
      read -rsp "Confirm: "                 PASS2; echo
      if [[ "$PASS" != "$PASS2" ]]; then
        echo "Passwords do not match" >&2
        exit 1
      fi

      ADMIN_FLAG="false"
      [[ "$ADMIN" == "yes" ]] && ADMIN_FLAG="true"

      # Use the admin-API registration endpoint. See:
      # https://element-hq.github.io/synapse/latest/admin_api/register_api.html
      NONCE="$(curl -sf "$ADMIN_URL/_synapse/admin/v1/register" | jq -r .nonce)"
      MAC="$(printf '%s\0%s\0%s\0%s' "$NONCE" "$USER" "$PASS" "$ADMIN_FLAG" \
        | openssl dgst -sha1 -hmac "$SHARED_SECRET" | awk '{print $2}')"

      curl -sf -X POST -H 'Content-Type: application/json' \
        -d "$(jq -n --arg n "$NONCE" --arg u "$USER" --arg p "$PASS" \
                   --arg m "$MAC" --argjson a $ADMIN_FLAG \
             '{nonce:$n, username:$u, password:$p, admin:$a, mac:$m}')" \
        "$ADMIN_URL/_synapse/admin/v1/register" | jq .
    '';
  };

  # One-shot bootstrap of matrix-secrets. Generates random hex tokens
  # for macaroon / form / registration / AS tokens, asks for a maubot
  # admin password to bcrypt, then creates (or refreshes only
  # REPLACE_ME placeholders in) the in-cluster Secret + the four
  # appservice-registration ConfigMaps.
  #
  #   nix run .#k8s-matrix-bootstrap-secrets
  #
  # Idempotent: re-running with the same arguments is safe; if the
  # Secret already exists the script refuses to overwrite unless
  # --force is passed.
  bootstrapSecrets = pkgs.writeShellApplication {
    name = "k8s-matrix-bootstrap-secrets";
    runtimeInputs = with pkgs; [ sshpass openssh coreutils openssl apacheHttpd ];
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

      # NOTE: `export KUBECONFIG=...; $*` rather than the prefix form
      # `KUBECONFIG=... $*` — the prefix form only decorates the first
      # command in a pipeline, so `kubectl ... | kubectl apply -f -`
      # would run the second kubectl without KUBECONFIG.
      ssh_exec() {
        sshpass -p ${constants.ssh.password} ssh \
          -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          -o LogLevel=ERROR \
          root@"$CP0_IP" \
          "export KUBECONFIG=/var/lib/kubernetes/pki/admin-kubeconfig; $*"
      }

      if [[ "$FORCE" != "yes" ]] && ssh_exec "kubectl -n matrix get secret matrix-secrets" >/dev/null 2>&1; then
        echo "matrix-secrets already exists. Pass --force to overwrite."
        exit 1
      fi

      # Generate tokens (hex for AS/HS; base64 for high-entropy keys).
      MACAROON="$(openssl rand -hex 32)"
      FORM="$(openssl rand -hex 32)"
      REGISTRATION="$(openssl rand -hex 32)"
      HOOKSHOT_AS="$(openssl rand -hex 32)"
      HOOKSHOT_HS="$(openssl rand -hex 32)"
      MAUBOT_AS="$(openssl rand -hex 32)"
      MAUBOT_HS="$(openssl rand -hex 32)"
      MAUBOT_UNSHARED="$(openssl rand -hex 32)"
      DISCORD_AS="$(openssl rand -hex 32)"
      DISCORD_HS="$(openssl rand -hex 32)"

      # --- Load operator secrets (optional) --------------------------
      # Maubot admin password can live in ~/.ssh/nix-k8s-examples-secrets
      # (kept outside the repo, so never in git). File must be mode
      # 0600/0400 and owned by the invoking user — the script refuses
      # to source anything laxer. Missing file / unset var falls back
      # to an interactive prompt.
      #
      # Example contents (chmod 600 after writing):
      #     MAUBOT_ADMIN="correct horse battery staple"
      SECRETS_FILE="$HOME/.ssh/nix-k8s-examples-secrets"
      if [[ -e "$SECRETS_FILE" ]]; then
        PERMS="$(stat -c '%a %u' "$SECRETS_FILE")"
        if [[ "$PERMS" != "600 $(id -u)" && "$PERMS" != "400 $(id -u)" ]]; then
          echo "Refusing to source $SECRETS_FILE: must be mode 0600/0400 and owned by $(id -un)." >&2
          echo "  Fix: chmod 600 $SECRETS_FILE" >&2
          exit 1
        fi
        # shellcheck source=/dev/null
        source "$SECRETS_FILE"
      fi

      # PG_PASS: always pull live from the cluster — the `pg-app`
      # Secret is the source of truth (managed by CNPG). No on-disk
      # copy, no paste errors.
      PG_PASS="$(ssh_exec "kubectl -n postgres get secret pg-app -o jsonpath='{.data.password}'" | base64 -d)"
      if [[ -z "$PG_PASS" ]]; then
        echo "Could not fetch pg-app password from cluster. Is postgres up?" >&2
        exit 1
      fi

      # MAUBOT_ADMIN: prefer the value sourced from SECRETS_FILE;
      # otherwise prompt.
      if [[ -z "''${MAUBOT_ADMIN:-}" ]]; then
        read -rsp "Maubot admin password: " MAUBOT_ADMIN; echo
      fi

      MAUBOT_BCRYPT="$(htpasswd -nbB admin "$MAUBOT_ADMIN" | cut -d: -f2)"

      # Assemble homeserver.secrets.yaml with the database block + the
      # three *_secret keys.
      SECRETS_YAML=$(cat <<EOF
macaroon_secret_key: "$MACAROON"
form_secret: "$FORM"
registration_shared_secret: "$REGISTRATION"
database:
  name: psycopg2
  args:
    user: app
    password: "$PG_PASS"
    database: synapse
    host: pg-rw.postgres.svc.cluster.local
    port: 5432
    cp_min: 5
    cp_max: 10
EOF
)

      TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
      printf '%s\n' "$SECRETS_YAML"       > "$TMP/homeserver.secrets.yaml"
      printf '%s'   "$REGISTRATION"        > "$TMP/registration_shared_secret"

      # Copy to cp0 and apply the Secret there.
      sshpass -p ${constants.ssh.password} scp \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "$TMP/homeserver.secrets.yaml"       root@"$CP0_IP":/tmp/
      sshpass -p ${constants.ssh.password} scp \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "$TMP/registration_shared_secret"    root@"$CP0_IP":/tmp/

      ssh_exec "kubectl -n matrix create secret generic matrix-secrets \
        --from-file=homeserver.secrets.yaml=/tmp/homeserver.secrets.yaml \
        --from-file=registration_shared_secret=/tmp/registration_shared_secret \
        --from-literal=pg_app_password='$PG_PASS' \
        --from-literal=hookshot_as_token='$HOOKSHOT_AS' \
        --from-literal=hookshot_hs_token='$HOOKSHOT_HS' \
        --from-literal=maubot_as_token='$MAUBOT_AS' \
        --from-literal=maubot_hs_token='$MAUBOT_HS' \
        --from-literal=maubot_unshared_secret='$MAUBOT_UNSHARED' \
        --from-literal=maubot_admin_bcrypt='$MAUBOT_BCRYPT' \
        --from-literal=mautrix_discord_as_token='$DISCORD_AS' \
        --from-literal=mautrix_discord_hs_token='$DISCORD_HS' \
        --dry-run=client -o yaml | kubectl apply -f -"

      ssh_exec "rm -f /tmp/homeserver.secrets.yaml /tmp/registration_shared_secret"

      # Patching the appservice-registration ConfigMaps with the real
      # AS/HS tokens is left to the operator — each bridge's
      # registration.yaml has its own format, and ArgoCD ignoreDifferences
      # on /data prevents the paste from being reverted. See
      # docs/matrix.md § "Bootstrapping secrets" for the kubectl form.
      echo ""
      echo "=== matrix-secrets created ==="
      echo "Tokens written to the Secret (fetch via kubectl -n matrix get secret matrix-secrets -o yaml):"
      echo "  hookshot_as_token        : $HOOKSHOT_AS"
      echo "  hookshot_hs_token        : $HOOKSHOT_HS"
      echo "  maubot_as_token          : $MAUBOT_AS"
      echo "  maubot_hs_token          : $MAUBOT_HS"
      echo "  maubot_unshared_secret   : $MAUBOT_UNSHARED"
      echo "  mautrix_discord_as_token : $DISCORD_AS"
      echo "  mautrix_discord_hs_token : $DISCORD_HS"
      echo ""
      echo "Next: manually patch the appservice-registration ConfigMaps with"
      echo "the tokens above. See docs/matrix.md § 'Bootstrapping secrets'."
    '';
  };
}
