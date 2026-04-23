# nix/registry-scripts.nix
#
# Operator helpers for the in-cluster OCI registry (Zot).
#
#   k8s-registry-bootstrap-secrets
#     Populates the two Secrets ArgoCD ships as placeholders:
#       * registry-htpasswd — bcrypted line for the push user
#         (password printed once; stash it in a password manager).
#       * registry-tls      — cluster-CA-signed leaf pulled from
#         cp0's node PKI dir (/var/lib/kubernetes/pki/registry-tls.*).
#     Idempotent; rotate with --force.
#
#   k8s-registry-push <image-tar-or-docker-archive> <repo:tag>
#     skopeo-copies a local image (e.g. a `dockerTools.buildImage`
#     result) into registry.lab.local, authenticated as the push
#     user. Reads the push password from a bootstrapped credentials
#     file (default: $HOME/.config/k8s-registry/creds) unless
#     REGISTRY_PUSH_PASSWORD is set in the environment.
#
{ pkgs }:
let
  constants = import ./constants.nix;
  r = constants.registry;
  credsPathDefault = "$HOME/.config/k8s-registry/creds";
in
{
  bootstrapSecrets = pkgs.writeShellApplication {
    name = "k8s-registry-bootstrap-secrets";
    runtimeInputs = with pkgs; [ sshpass openssh coreutils openssl apacheHttpd ];
    text = ''
      set -euo pipefail

      FORCE="no"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --force) FORCE="yes"; shift ;;
          *) echo "Usage: k8s-registry-bootstrap-secrets [--force]" >&2; exit 2 ;;
        esac
      done

      CP0_IP="${constants.network.ipv4.cp0}"
      NS="${r.namespace}"

      ssh_exec() {
        sshpass -p ${constants.ssh.password} ssh \
          -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          -o LogLevel=ERROR \
          root@"$CP0_IP" \
          "export KUBECONFIG=/var/lib/kubernetes/pki/admin-kubeconfig; $*"
      }

      # Idempotency guard: if both Secrets already hold non-placeholder
      # values, refuse without --force.
      if [[ "$FORCE" != "yes" ]]; then
        CUR_HT=$(ssh_exec "kubectl -n $NS get secret registry-htpasswd -o jsonpath='{.data.htpasswd}'" 2>/dev/null | base64 -d 2>/dev/null || true)
        CUR_TLS=$(ssh_exec "kubectl -n $NS get secret registry-tls -o jsonpath='{.data.tls\\.crt}'" 2>/dev/null | base64 -d 2>/dev/null || true)
        if [[ -n "$CUR_HT" && "$CUR_HT" != *"__BOOTSTRAPPED_OUT_OF_BAND__"* && \
              -n "$CUR_TLS" && "$CUR_TLS" != *"__BOOTSTRAPPED_OUT_OF_BAND__"* ]]; then
          echo "registry-htpasswd + registry-tls already populated. Pass --force to rotate."
          exit 1
        fi
      fi

      # Fresh push-user password.
      PUSH_PASS=$(openssl rand -hex 24)
      HTPASSWD_LINE=$(htpasswd -nbB "${r.pushUser}" "$PUSH_PASS")

      # Read the cluster-CA-signed leaf from cp0's PKI dir. Present on
      # every node (baked into the VM image via nix/certs.nix), but cp0
      # is where we're already SSHed.
      TLS_CRT=$(ssh_exec "cat /var/lib/kubernetes/pki/registry-tls.crt")
      TLS_KEY=$(ssh_exec "cat /var/lib/kubernetes/pki/registry-tls.key")

      # Create/update the two Secrets.
      ssh_exec "kubectl -n $NS create secret generic registry-htpasswd \
        --from-literal=htpasswd='$HTPASSWD_LINE' \
        --dry-run=client -o yaml | kubectl apply -f -"

      # Use a here-doc piped through SSH so newlines in the cert
      # survive. `kubectl create secret tls` needs the cert + key as
      # files; we shove them through stdin by base64ing locally.
      TLS_CRT_B64=$(printf '%s' "$TLS_CRT" | base64 -w0)
      TLS_KEY_B64=$(printf '%s' "$TLS_KEY" | base64 -w0)
      ssh_exec "cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: registry-tls
  namespace: $NS
type: kubernetes.io/tls
data:
  tls.crt: $TLS_CRT_B64
  tls.key: $TLS_KEY_B64
EOF"

      # Stash the push creds locally so k8s-registry-push can find them.
      CREDS_DIR="$HOME/.config/k8s-registry"
      mkdir -p "$CREDS_DIR"
      chmod 700 "$CREDS_DIR"
      CREDS_FILE="$CREDS_DIR/creds"
      umask 077
      cat > "$CREDS_FILE" <<EOF
REGISTRY_PUSH_USER=${r.pushUser}
REGISTRY_PUSH_PASSWORD=$PUSH_PASS
REGISTRY_HOST=${r.host}
EOF

      # Nudge Zot to pick up the fresh htpasswd + cert.
      ssh_exec "kubectl -n $NS rollout restart deploy/zot" || true

      echo ""
      echo "=== registry bootstrap complete ==="
      echo "  Push user:      ${r.pushUser}"
      echo "  Push password:  $PUSH_PASS"
      echo "  Creds file:     $CREDS_FILE"
      echo ""
      echo "Push a Nix-built image with:"
      echo "  nix run .#k8s-registry-push -- ./result <repo>:<tag>"
    '';
  };

  push = pkgs.writeShellApplication {
    name = "k8s-registry-push";
    runtimeInputs = with pkgs; [ skopeo coreutils ];
    text = ''
      set -euo pipefail

      if [[ $# -ne 2 ]]; then
        cat >&2 <<USAGE
      Usage: k8s-registry-push <image-archive> <repo:tag>

        <image-archive>  Path to a docker-archive tarball produced by
                         dockerTools.buildImage (e.g. ./result).
        <repo:tag>       Destination tag within the registry.
                         Pushed to ${r.host}/<repo>:<tag>.

      Reads push credentials from \$REGISTRY_PUSH_PASSWORD if set, else
      from ${credsPathDefault} (written by
      k8s-registry-bootstrap-secrets).
      USAGE
        exit 2
      fi

      SRC="$1"
      DEST_REF="$2"

      if [[ -z "''${REGISTRY_PUSH_PASSWORD:-}" ]]; then
        CREDS_FILE="${credsPathDefault}"
        if [[ ! -r "$CREDS_FILE" ]]; then
          echo "No push password in env and $CREDS_FILE missing." >&2
          echo "Run: nix run .#k8s-registry-bootstrap-secrets" >&2
          exit 1
        fi
        # shellcheck disable=SC1090
        source "$CREDS_FILE"
      fi

      USER="''${REGISTRY_PUSH_USER:-${r.pushUser}}"
      HOST="''${REGISTRY_HOST:-${r.host}}"

      echo "Pushing $SRC → $HOST/$DEST_REF"
      skopeo copy \
        --dest-creds="$USER:$REGISTRY_PUSH_PASSWORD" \
        "docker-archive:$SRC" \
        "docker://$HOST/$DEST_REF"
      echo "OK"
    '';
  };
}
