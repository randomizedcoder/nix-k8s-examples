# Secrets Management

Offline pre-generation of application secrets, automatically injected at
cluster boot. Zero manual steps after `k8s-gen-secrets`.

## Quick Start

```bash
nix run .#k8s-gen-secrets          # generate 19 secret files into ./secrets/
nix run .#k8s-cluster-rebuild      # cluster builds with secrets baked in
```

To rotate all secrets:

```bash
nix run .#k8s-gen-secrets -- --force   # regenerate
nix run .#k8s-cluster-rebuild          # rebuild picks up new values
```

## Architecture

```
Offline (host):
  nix run .#k8s-gen-secrets     -->  ./secrets/  (19 files, git-staged)
                                       |- anubis-ed25519-key
                                       |- matrix-{macaroon,form,registration,...} (11 files)
                                       |- ch-{otel,hyperdx}-password
                                       |- registry-push-password
                                       |- pdns-{api-key,tsig-secret}
                                       '- ssh-ed25519{,.pub}

Build time (nix build):
  nix/secrets.nix reads ./secrets/  -->  k8s-secrets derivation + sshPubKey
    - bcrypt hashes (maubot admin, registry htpasswd)
    - JSON configs (ClickStack connections.json, sources.json)
    - homeserver.secrets.yaml (PG password = placeholder)
    - 7 K8s Secret manifests (JSON format)
    - SSH public key → baked into each VM's authorized_keys

Boot time (cp0 first boot):
  gitops-bootstrap-module.nix step 2b:
    kubectl apply -f <secretsPath>/*.json
  step 2c:
    registry-tls Secret created from node PKI files (same CA build)
  step 4:
    wait for CNPG pg-app Secret -> patch matrix homeserver.secrets.yaml

Post-boot (automated):
  - CH DDL Job: CREATE USER otel/hyperdx using pre-generated passwords
  - registry-push service: skopeo push hubble-otel image into Zot
```

## Secrets Inventory

| Raw file in `./secrets/` | K8s Secret | Namespace | Notes |
|---|---|---|---|
| `anubis-ed25519-key` | `anubis-secrets` | nginx | ED25519 signing key for PoW cookies |
| `matrix-macaroon` | `matrix-secrets` | matrix | Synapse macaroon_secret_key |
| `matrix-form` | `matrix-secrets` | matrix | Synapse form_secret |
| `matrix-registration` | `matrix-secrets` | matrix | Synapse registration_shared_secret |
| `matrix-hookshot-{as,hs}` | `matrix-secrets` | matrix | Bridge appservice tokens |
| `matrix-maubot-{as,hs}` | `matrix-secrets` | matrix | Maubot appservice tokens |
| `matrix-maubot-unshared` | `matrix-secrets` | matrix | Maubot unshared secret |
| `matrix-maubot-admin` | `matrix-secrets` | matrix | Maubot admin password (bcrypted at build) |
| `matrix-discord-{as,hs}` | `matrix-secrets` | matrix | Discord bridge tokens |
| `ch-otel-password` | `otel-ch-credentials` | observability | CH `otel` writer password |
| `ch-hyperdx-password` | `otel-ch-credentials` + `clickstack-hyperdx-config` | observability | CH `hyperdx` reader password |
| `registry-push-password` | `registry-htpasswd` | registry | Zot push user password (bcrypted at build) |
| `pdns-api-key` | `pdns-credentials` | pdns | PowerDNS API key |
| `pdns-tsig-secret` | `pdns-credentials` + `pdns-tsig-secret` | pdns, cert-manager | TSIG key for RFC2136 dynamic DNS updates |
| `ssh-ed25519` | *(host only)* | -- | SSH private key for MicroVM access |
| `ssh-ed25519.pub` | *(baked into VMs)* | -- | SSH public key → `authorized_keys` on all VMs |

**Not pre-generated (handled at runtime):**

- `argocd-redis` -- generated at boot in the bootstrap module (`/dev/urandom`)
- `pg-app` -- CNPG auto-generates when the Cluster CR is applied. The matrix
  `homeserver.secrets.yaml` gets the PG password patched live by the bootstrap
  module after CNPG creates the Secret.
- `registry-tls` -- created at boot by the bootstrap module (step 2c) from the
  node's `/var/lib/kubernetes/pki/registry-tls.{crt,key}`. Reading from the
  local filesystem guarantees the cert matches the CA that all nodes trust.
  (The PKI store is non-deterministic; a separate Nix derivation could get a
  different CA build due to garbage collection.)

## How It Works

### 1. Generate secrets

```bash
nix run .#k8s-gen-secrets
```

Creates `./secrets/` with 19 files: 16 random hex secrets, 1 base64
TSIG key, plus an SSH ED25519 key pair (`ssh-ed25519` +
`ssh-ed25519.pub`). Most secrets are
`openssl rand -hex 32` (64-char hex); the registry password is
`openssl rand -hex 24`. The maubot admin password can be set via
`$MAUBOT_ADMIN` env var; otherwise random.

The SSH public key is baked into each MicroVM's `authorized_keys` at
build time, enabling `ssh -i secrets/ssh-ed25519 root@<vm-ip>`.

The script also runs `git add secrets/` so Nix flakes can see the files
(flakes can only read git-tracked files).

### 2. Nix build reads secrets

`nix/secrets.nix` uses `builtins.pathExists ../secrets` to detect whether
secrets exist. If yes, it:

- Reads all 17 raw files via `builtins.readFile`
- Derives bcrypt hashes (htpasswd for registry, bcrypt for maubot admin)
- Derives JSON configs (ClickStack connections.json and sources.json)
- Builds `homeserver.secrets.yaml` with a `__PG_PASSWORD_INJECTED_AT_BOOT__`
  placeholder for the PG password (CNPG owns that)
- Emits 7 K8s Secret manifests as JSON files in a `k8sSecrets` derivation

If `./secrets/` doesn't exist, `k8sSecrets = null` and the cluster builds
normally -- Secrets keep their `__BOOTSTRAPPED_OUT_OF_BAND__` placeholders.

### 3. Bootstrap applies secrets

`nix/gitops-bootstrap-module.nix` step 2b (between ArgoCD install and
Application CRs) applies all `*.json` files from `secretsPath`:

```
1.  Cilium install
1b. Base manifests (namespaces, RBAC, CoreDNS)
2.  ArgoCD install
2b. Pre-generated Secrets
2c. registry-tls Secret (from node PKI files)
3.  Application CRs
4.  PG password patching
```

Step 2c creates the `registry-tls` K8s Secret from the node's local
PKI files (`/var/lib/kubernetes/pki/registry-tls.{crt,key}`), ensuring
the cert matches the CA that all nodes trust.

Step 4 waits up to 10 minutes for CNPG to create the `pg-app` Secret,
then patches `matrix-secrets` with the real PG password.

### 4. CH user-creation Job

A K8s Job (`otel-ch-users`) in the observability namespace runs
`CREATE USER` / `GRANT` DDL against ClickHouse using the pre-generated
passwords from the `otel-ch-credentials` Secret. Annotated with
`argocd.argoproj.io/hook: Sync` so ArgoCD runs it on each sync.
Idempotent: all DDL uses `IF NOT EXISTS` / `ALTER USER`.

### 5. Registry image push

A systemd oneshot (`k8s-registry-push.service`) on cp0 runs after
bootstrap. It waits for the registry to be ready, reads the push password
from the `registry-htpasswd` Secret, and pushes the hubble-otel image
via skopeo. A marker file prevents re-runs.

## Design Decisions

**Why `builtins.pathExists` (graceful degradation)?**
The cluster must build and boot without secrets for development and CI.
If `./secrets/` doesn't exist, `k8sSecrets = null` and the bootstrap
module skips step 2b. Workloads with placeholder Secrets will crashloop
until real credentials arrive (either via the old manual scripts or a
future `k8s-gen-secrets` + rebuild).

**Why PG password is patched live?**
CNPG is the source of truth for the `pg-app` Secret. It generates the
password when the Cluster CR is applied (step 3). We can't pre-generate
it because CNPG would overwrite our value. Instead, we wait for CNPG
and patch the matrix Secret with the real password.

**Why CH DDL is a Job, not a script?**
The Job runs inside the cluster where it can reach ClickHouse directly.
It retries automatically on failure (`backoffLimit: 10`) and integrates
with ArgoCD's sync lifecycle (`hook: Sync`).

**Why registry-tls comes from PKI, not secrets/?**
The registry TLS cert is signed by the cluster CA (from `certs.nix`).
It's a certificate, not a random secret -- it belongs with the PKI
infrastructure.

**Why JSON, not YAML, for Secret manifests?**
Bcrypt hashes contain `$` characters that break shell heredocs.
`jq` handles all quoting correctly, and `kubectl apply` accepts JSON
natively.

**Why git-staged, not gitignored?**
Nix flakes can only read git-tracked files. Since secrets must be
readable by `builtins.readFile` at eval time, they must be staged.
The `k8s-gen-secrets` script handles this automatically. Review
discipline prevents accidental commits.

## Comparison with Previous Workflow

### Before (4 manual steps)

```bash
nix run .#k8s-cluster-rebuild
# wait for cluster...
nix run .#k8s-anubis-bootstrap-secrets
nix run .#k8s-matrix-bootstrap-secrets       # interactive prompt for maubot password
nix run .#k8s-observability-bootstrap-secrets
nix run .#k8s-registry-bootstrap-secrets
nix run .#k8s-registry-push -- $(nix build .#hubble-otel-image --print-out-paths) hubble-otel:6f5fe85
```

### After (1 offline step)

```bash
nix run .#k8s-gen-secrets         # offline, one time (or --force to rotate)
nix run .#k8s-cluster-rebuild     # everything automated
```

## File Map

| File | Purpose |
|---|---|
| `nix/secrets-gen.nix` | `k8s-gen-secrets` writeShellApplication |
| `nix/secrets.nix` | Reads `./secrets/`, derives artifacts, emits K8s Secret JSON |
| `nix/gitops-bootstrap-module.nix` | Step 2b (apply secrets) + step 4 (PG password patch) |
| `nix/microvm.nix` | Passes `k8sSecrets` to bootstrap, adds registry-push service |
| `nix/gitops/env/observability.nix` | CH DDL Job manifest (`otel-ch-users`) |
| `nix/gitops/env/pdns.nix` | PowerDNS manifests (DaemonSet, schema Jobs, Cilium LB) |
| `flake.nix` | Wires secrets.nix, secrets-gen.nix, hubbleOtelImage into build |
