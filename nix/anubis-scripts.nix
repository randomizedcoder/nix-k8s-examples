# nix/anubis-scripts.nix
#
# Operator helper for the Anubis anti-scraper fronting nginx. One
# bootstrap helper that generates the ED25519 signing key Anubis uses
# to mint proof-of-work cookies, and stores it in the `anubis-secrets`
# Secret in the `nginx` namespace. Key rotation = `--force`.
#
{ pkgs }:
let
  constants = import ./constants.nix;
in
{
  # One-shot bootstrap of anubis-secrets. Generates a random 32-byte
  # hex key and creates (or refreshes, with --force) the in-cluster
  # Secret. Idempotent re-runs without --force are refused.
  #
  #   nix run .#k8s-anubis-bootstrap-secrets
  #
  # After the Secret exists, rollout-restart the anubis Deployment
  # (the pod crashloops until the Secret is present).
  bootstrapSecrets = pkgs.writeShellApplication {
    name = "k8s-anubis-bootstrap-secrets";
    runtimeInputs = with pkgs; [ sshpass openssh coreutils openssl ];
    text = ''
      set -euo pipefail

      FORCE="no"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --force) FORCE="yes"; shift ;;
          *) echo "Usage: k8s-anubis-bootstrap-secrets [--force]" >&2; exit 2 ;;
        esac
      done

      CP0_IP="${constants.network.ipv4.cp0}"

      # NOTE: `export KUBECONFIG=...; $*` — the prefix form
      # `KUBECONFIG=... $*` only decorates the first command in a
      # pipeline, so `kubectl ... | kubectl apply -f -` would run the
      # second kubectl without KUBECONFIG.
      ssh_exec() {
        sshpass -p ${constants.ssh.password} ssh \
          -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          -o LogLevel=ERROR \
          root@"$CP0_IP" \
          "export KUBECONFIG=/var/lib/kubernetes/pki/admin-kubeconfig; $*"
      }

      if [[ "$FORCE" != "yes" ]] && ssh_exec "kubectl -n nginx get secret anubis-secrets" >/dev/null 2>&1; then
        echo "anubis-secrets already exists. Pass --force to rotate."
        exit 1
      fi

      KEY="$(openssl rand -hex 32)"

      ssh_exec "kubectl -n nginx create secret generic anubis-secrets \
        --from-literal=ed25519_private_key_hex='$KEY' \
        --dry-run=client -o yaml | kubectl apply -f -"

      echo ""
      echo "=== anubis-secrets created ==="
      echo "Rollout-restart the anubis Deployment to pick up the new key:"
      echo "  kubectl -n nginx rollout restart deploy/anubis"
    '';
  };
}
