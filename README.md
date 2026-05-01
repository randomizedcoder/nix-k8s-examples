# K8s MicroVM Cluster

HA Kubernetes cluster (3 control planes + 1 worker) running as NixOS MicroVMs with QEMU. All PKI is generated at Nix build time and baked into VM images. Host-side haproxy provides apiserver HA. Uses Cilium CNI (replacing kube-proxy), dual-stack networking, CoreDNS, and GitOps deployment via ArgoCD.

- **Ingress**: Cilium's built-in ingress controller (Envoy), exposed via a single L2-announced LoadBalancer VIP (`10.33.33.50`) — no separate ingress-nginx DaemonSet, no host haproxy HTTP/S fanout. Phase-2 upgrade is a Cilium L2→BGP flip; VIP, Service, and Ingress stay the same.

## Architecture

```
Host Machine (NixOS)
├── k8sbr0 (bridge): 10.33.33.1/24, fd33:33:33::1/64
│   ├── k8stap0 → cp0  10.33.33.10  (8GB RAM, 4 vCPU)
│   ├── k8stap1 → cp1  10.33.33.11  (8GB RAM, 4 vCPU)
│   ├── k8stap2 → cp2  10.33.33.12  (8GB RAM, 4 vCPU)
│   └── k8stap3 → w3   10.33.33.13  (6GB RAM, 2 vCPU)
├── haproxy on 10.33.33.1:6443 → load-balances to cp0, cp1, cp2
├── nftables NAT: masquerade outbound only (VM-to-VM traffic stays un-NATed)
└── IP forwarding enabled (v4 + v6)

K8s Internal Networks (Cilium-managed):
  Pod CIDR:     10.244.0.0/16, fd44:44:44::/48
  Service CIDR: 10.96.0.0/12,  fd96:96:96::/108
  Ingress VIP:  10.33.33.50  (Cilium L2-announced, leader node ARP-replies)

HA: 3-node etcd quorum (tolerates 1 CP failure), haproxy LB for apiserver
```

**cp0, cp1, cp2** (control planes): etcd, kube-apiserver, kube-controller-manager, kube-scheduler, containerd, kubelet
**w3** (worker): containerd, kubelet

## Quick Start

```bash
# 1. Enter the dev shell (kubectl, helm, cilium-cli, hubble, argocd, step-cli, ...)
nix develop

# 2. Verify the host has /dev/net/tun, vhost_net, bridge module, sudo
nix run .#k8s-check-host

# 3. Create bridge, 4 TAP devices, nftables NAT, haproxy apiserver LB
sudo nix run .#k8s-network-setup

# 4. Generate application secrets (one time; regenerate with --force)
nix run .#k8s-gen-secrets

# 5. Build and start all 4 VMs — bootstrap runs automatically on cp0
nix run .#k8s-start-all

# 6. Watch bootstrap progress (Cilium → CoreDNS → ArgoCD → Secrets → Applications)
nix run .#k8s-vm-ssh -- --node=cp0 journalctl -fu k8s-gitops-bootstrap

# 7. Verify the cluster
nix run .#k8s-vm-ssh -- --node=cp0 kubectl get nodes
nix run .#k8s-vm-ssh -- --node=cp0 kubectl get pods -A
```

PKI is generated at build time and baked into VM images — no separate cert step needed.
Application secrets (CH passwords, Matrix tokens, Anubis key, registry credentials) are
pre-generated offline by step 4 and injected automatically at boot. See
[docs/secrets.md](docs/secrets.md) for the full design.

### Wipe and Rebuild

The cluster can be completely torn down and rebuilt from scratch at any time:

```bash
# Stop all VMs, delete data images, start fresh — bootstrap re-runs automatically
nix run .#k8s-cluster-rebuild

# Or separately:
nix run .#k8s-vm-wipe          # Stop VMs + delete data images
nix run .#k8s-start-all        # Rebuild from scratch
```

## Services & Access

After bootstrap completes (~2 minutes), the following services are accessible from the host:

### Kubernetes API

| Service | URL | Notes |
|---------|-----|-------|
| API Server (via haproxy LB) | `https://10.33.33.1:6443` | Load-balanced across 3 CPs |
| API Server (direct cp0) | `https://10.33.33.10:6443` | Direct access to individual CP |

```bash
# SSH and run kubectl (uses in-VM kubeconfig)
nix run .#k8s-vm-ssh -- --node=cp0 kubectl get nodes
nix run .#k8s-vm-ssh -- --node=cp0 kubectl get pods -A
nix run .#k8s-vm-ssh -- --node=cp0 kubectl -n argocd get applications
```

### ArgoCD

| Service | URL | Notes |
|---------|-----|-------|
| ArgoCD UI | `https://10.33.33.10:30443` | NodePort (any node IP works) |

ArgoCD manages 12 Applications (cilium, argocd, base, cert-manager, clickhouse, foundationdb, matrix, nginx, observability, registry, tidb, postgres) via the rendered manifests pattern. After first boot, ArgoCD is the source of truth via git.

```bash
# Get the initial admin password
nix run .#k8s-vm-ssh -- --node=cp0 kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d

# CLI access (from dev shell)
argocd login 10.33.33.10:30443 --insecure --username admin --password <password>
argocd app list
```

### Hubble (Network Observability)

| Service | URL | Notes |
|---------|-----|-------|
| Hubble UI | `http://10.33.33.10:31234` | Web dashboard for flow visibility |
| Hubble Relay | `grpc://10.33.33.10:31245` | gRPC endpoint for hubble CLI |

```bash
# Open in browser
xdg-open http://10.33.33.10:31234

# CLI access (from dev shell — TLS disabled for test cluster)
hubble --server 10.33.33.10:31245 status
hubble --server 10.33.33.10:31245 observe --last 20
```

### Monitoring

| Service | URL | Notes |
|---------|-----|-------|
| Prometheus | `http://10.33.33.10:9090` | On cp0, 15-day retention |
| Grafana | `http://10.33.33.10:3000` | admin/admin |
| node-exporter | `http://10.33.33.{10,11,12,13}:9100` | All nodes |
| Cilium Agent metrics | `:9962` on all nodes | Prometheus scrape target |
| Cilium Operator metrics | `:9963` | Single instance |
| Hubble metrics | `:9965` on all nodes | Flow metrics |

### TiDB (Distributed SQL)

| Service | URL | Notes |
|---------|-----|-------|
| TiDB (MySQL protocol) | `mysql -h 10.33.33.10 -P 30400 -u root` | NodePort (any node IP) |
| PD Dashboard | `http://pd.tidb.svc.cluster.local:2379/dashboard` | In-cluster only |

TiDB provides a MySQL-compatible distributed SQL database with 3 PD nodes (Raft metadata), 4 TiKV storage nodes, and 2 stateless TiDB SQL servers. A sysbench benchmark job runs automatically after deployment.

### PostgreSQL (CloudNativePG)

| Service | URL | Notes |
|---------|-----|-------|
| Primary (rw) | `psql -h 10.33.33.10 -p 30500 -U app app` | Writes land here; auto-failover via CNPG |
| Any replica (ro) | `psql -h 10.33.33.10 -p 30501 -U app app` | Read-only; streaming replication |

A CloudNativePG-managed HA PostgreSQL cluster with 1 primary + 3 replicas (one per physical node via pod anti-affinity). Streaming replication from primary to replicas; on primary failure, a replica is promoted automatically. Backed by local-path-provisioner for node-local PVs (data is not replicated across nodes at the storage layer — replication is at the PG level).

### ClickHouse

| Service | URL | Notes |
|---------|-----|-------|
| ClickHouse (HTTP) | `http://10.33.33.10:30423` | NodePort (any node IP) |
| ClickHouse (native) | `clickhouse-client --host 10.33.33.10 --port 30900` | Native protocol |

### Matrix (Chat)

| Service | URL | Notes |
|---------|-----|-------|
| Element Web | `https://element.lab.local` | Cilium Ingress (Envoy) on L2-announced VIP `10.33.33.50` |
| Synapse client API | `https://matrix.lab.local/_matrix/client/versions` | Same path |
| Hookshot webhooks | `https://hookshot.lab.local/webhook/` | Same path |
| maubot admin UI | `https://maubot.lab.local` | Same path |
| Synapse admin API | `http://10.33.33.10:30800` | NodePort — used by `k8s-matrix-register-user` |

Self-hosted Matrix homeserver (Synapse) + Element Web client + matrix-hookshot (GitHub/GitLab/Jira webhooks) + maubot (bot plugin host) + mautrix-discord (Discord bridge). Serves an open-source community — humans chat, bots automate, external systems post via webhooks. Phase 1 exposes the stack through Cilium Ingress (Envoy) on an L2-announced VIP inside the lab bridge; phase 2 flips Cilium from L2 announcements to BGP control plane — same VIP, same Service, same Ingress. See [docs/matrix.md](docs/matrix.md) for the full operator guide.

```bash
# 1. /etc/hosts on the dev host:
#    10.33.33.50 matrix.lab.local element.lab.local hookshot.lab.local maubot.lab.local hello.lab.local clickstack.lab.local

# 2. Generate secrets (tokens, bcrypt'd maubot admin password) once per cluster:
nix run .#k8s-matrix-bootstrap-secrets

# 3. Register a user:
nix run .#k8s-matrix-register-user -- --username=alice

# 4. Browse to https://element.lab.local (accept the self-signed cert), log in as alice.
```

Permanent decision: `server_name = matrix.lab.local`. Matrix bakes this into every
signed event — changing it later requires wiping the Synapse DB. See docs/matrix.md
§ "server_name is forever".

### Hello-World (Anubis-protected)

| Service | URL | Notes |
|---------|-----|-------|
| Hello-world page | `https://hello.lab.local/` | Public entry point — served by nginx via Anubis challenge. Browsers get a one-time PoW challenge; subsequent requests are cookie-authenticated |
| Anubis PoW challenge (same URL) | `https://hello.lab.local/` (no `Anubis` cookie) | First request returns the Anubis HTML challenge page; solving it sets a signed cookie valid for the configured challenge TTL |
| Anubis metrics (cluster-internal) | `http://anubis.nginx.svc.cluster.local:9090/metrics` | Prometheus-format; not exposed externally |
| nginx backend (cluster-internal) | `http://nginx.nginx.svc.cluster.local:80/` | ClusterIP only — no NodePort, no external path that bypasses Anubis |

```
┌──────────────────────────────────────────────────────────────────────┐
│  Dev host                                                            │
│     /etc/hosts: 10.33.33.50  hello.lab.local                         │
│             │                                                        │
│             ▼   HTTPS :443                                           │
│  ┌────────────────────┐  TLS terminates                              │
│  │ Cilium Ingress     │  (cert-manager / selfsigned-lab)             │
│  │ VIP 10.33.33.50    │                                              │
│  └─────────┬──────────┘                                              │
│            │   HTTP :8080                                            │
│            ▼                                                         │
│  ┌────────────────────┐  PoW challenge / cookie verify               │
│  │ anubis (Deployment)│  deny known scraper UAs                      │
│  │ ClusterIP :8080    │                                              │
│  └─────────┬──────────┘                                              │
│            │   HTTP :80                                              │
│            ▼                                                         │
│  ┌────────────────────┐  static hello-world                          │
│  │ nginx (ClusterIP)  │                                              │
│  └────────────────────┘                                              │
└──────────────────────────────────────────────────────────────────────┘
```

A tiny nginx page exists primarily as a target for [TecharoHQ/Anubis](https://github.com/TecharoHQ/anubis) — a proof-of-work reverse proxy that challenges suspicious User-Agents before forwarding to the backend. Known AI/scraper UAs (GPTBot, ClaudeBot, CCBot, PerplexityBot, Bytespider, Amazonbot, …) are DENY'd outright; mainstream browsers get a one-time PoW challenge and a signed cookie. nginx's Service is ClusterIP, so there is no NodePort bypass around Anubis.

```bash
# 1. /etc/hosts on the dev host (append hello.lab.local to the VIP line):
#    10.33.33.50 matrix.lab.local element.lab.local hookshot.lab.local maubot.lab.local hello.lab.local

# 2. Bootstrap Anubis' ED25519 signing key once per cluster (outside git,
#    written to the `anubis-secrets` Secret in ns=nginx):
nix run .#k8s-anubis-bootstrap-secrets

# 3. Roll out Anubis to pick up the new key:
nix run .#k8s-vm-ssh -- --node=cp0 \
  "KUBECONFIG=/var/lib/kubernetes/pki/admin-kubeconfig kubectl -n nginx rollout restart deploy/anubis"

# 4. Browser: open https://hello.lab.local/ (accept the self-signed cert),
#    watch the Anubis challenge page, then the hello-world body.

# 5. Smoke-test from the CLI:
#    - Browser-like UA → HTML challenge page:
curl -sk --resolve hello.lab.local:443:10.33.33.50 \
     -A 'Mozilla/5.0' https://hello.lab.local/ | head
#    - Known scraper UA → DENY (Anubis returns a 403/block page):
curl -sk --resolve hello.lab.local:443:10.33.33.50 \
     -A 'GPTBot/1.2 (+https://openai.com/gptbot)' \
     https://hello.lab.local/ -o /dev/null -w '%{http_code}\n'
```

Rotate the Anubis signing key: `nix run .#k8s-anubis-bootstrap-secrets -- --force` (then rollout-restart the Deployment). Tune the policy by editing `botPolicies.yaml` in `nix/gitops/env/nginx.nix` and re-rendering.

### Observability (ClickStack UI → ch4)

| Service | URL | Notes |
|---------|-----|-------|
| ClickStack UI (HyperDX) | `https://clickstack.lab.local/` | Cilium Ingress + `selfsigned-lab` cert. Backed by the ch4 ClickHouse cluster (`otel` database) and an emptyDir MongoDB. |
| OTel Collector `/metrics` | `http://<node-ip>:8888/metrics` | Each collector pod's self-telemetry (DS on all 4 CH nodes). |
| hubble-otel DS | `observability/hubble-otel` | DS on every CH node; reads Hubble L3/L4/L7 flows from the local cilium-agent and exports OTLP to the collector Service. Built from the archived `cilium/hubble-otel` repo via `nix build .#hubble-otel-image` and pushed to the in-cluster Zot registry. |
| Schema-bootstrap Job | `observability/otel-schema-bootstrap` | ArgoCD sync-wave 1 hook; applies the canonical OTel v0.140 DDL on every sync. |

Unified logs + traces + metrics pipeline: each node runs an OTel Collector DaemonSet that accepts OTLP over a UDS at `/var/run/otel/collector.sock` (zero-NIC ingress from co-located workloads), enriches with k8s attributes, and writes to a co-located ClickHouse replica via the `clickhouse-local` Service (`internalTrafficPolicy: Local`, native protocol port 9000). Prometheus on cp0 mirrors every scrape target into the collector via `prometheusremotewrite`. See [docs/observability.md](docs/observability.md) for the full architecture.

```bash
# 1. /etc/hosts on the dev host:
#    10.33.33.50 clickstack.lab.local

# 2. Provision CH users (otel writer, hyperdx reader) + populate Secrets:
nix run .#k8s-observability-bootstrap-secrets

# 3. Build + push the hubble-otel image into the in-cluster Zot registry.
#    (Upstream cilium/hubble-otel is archived with no container image,
#    so we rebuild from source via Go 1.26.)
IMG=$(nix build .#hubble-otel-image --print-out-paths)
nix run .#k8s-registry-push -- "$IMG" hubble-otel:6f5fe85

# 4. Browse to https://clickstack.lab.local (accept the self-signed cert).
```

Phase-1 scope: MongoDB runs on emptyDir (UI state resets on pod restart); the read-only browse-only OIDC hook lands in a follow-up PR — see docs/observability.md § "Phase-2".

### In-cluster OCI registry (Zot)

| Service | URL | Notes |
|---------|-----|-------|
| Zot registry | `https://registry.lab.local/` | Dedicated LB VIP `10.33.33.51` (separate from cilium-ingress `.50`). TLS leaf is cluster-CA-signed; every node trusts the cluster CA via `/etc/containerd/certs.d/registry.lab.local/hosts.toml`. Anonymous pull, htpasswd-gated push. |

Used by images Nix builds locally — starting with hubble-otel from the archived `cilium/hubble-otel` tree (see PR 5b). Containerd on every node resolves `registry.lab.local` via `networking.extraHosts` and validates the leaf against the cluster CA, so pulls "just work" without any per-cert rotation plumbing.

```bash
# 1. /etc/hosts on the dev host:
#    10.33.33.51 registry.lab.local

# 2. Generate htpasswd for the push user + populate the TLS Secret from
#    cp0's node PKI dir. Prints the push password once.
nix run .#k8s-registry-bootstrap-secrets

# 3. Push a Nix-built image (docker-archive tarball) into the registry:
nix build .#some-image              # produces ./result
nix run .#k8s-registry-push -- ./result myrepo:v1

# 4. Pull from any node:
crictl pull registry.lab.local/myrepo:v1
```

Rotate push creds + TLS: `nix run .#k8s-registry-bootstrap-secrets -- --force`. The TLS leaf itself rotates with the rest of the cluster PKI (30-day validity, regenerated on VM rebuild).

### Chaos / Failover Test

`nix run .#k8s-chaos-failover` runs a continuous light transactional workload against all four databases (PostgreSQL, TiDB, ClickHouse, FoundationDB), then stops and restarts one MicroVM at a time in a loop, measuring per-DB recovery time after each kill.

```bash
# Full default run: 10 rounds × 4 nodes, 60s interval — ~40 min
nix run .#k8s-chaos-failover

# Quick smoke: 1 round, 30s interval, 10s warmup
nix run .#k8s-chaos-failover -- --rounds=1 --interval=30 --warmup=10

# Skip FDB and fail only the worker
nix run .#k8s-chaos-failover -- --nodes=w3 --skip-dbs=fdb
```

Output is written to `./chaos-logs/`:
- `<db>.log` — per-transaction result with nanosecond timestamps
- `summary.tsv` — per-round, per-node, per-DB recovery time (seconds)
- `events.log` — human-readable event stream

Pair with `nix run .#k8s-vm-stop-one -- --node=<name>` and `nix run .#k8s-vm-start-one -- --node=<name>` for ad-hoc failure injection on a single node.

### SSH

| Node | IP | Password |
|------|----|----------|
| cp0 | 10.33.33.10 | `k8s` (root) |
| cp1 | 10.33.33.11 | `k8s` (root) |
| cp2 | 10.33.33.12 | `k8s` (root) |
| w3  | 10.33.33.13 | `k8s` (root) |

```bash
nix run .#k8s-vm-ssh -- --node=cp0        # Interactive shell
nix run .#k8s-vm-ssh -- --node=w3 uptime  # Run command on worker
```

### Serial Consoles

For boot debugging when SSH isn't available:

| Node | Serial (ttyS0) | Virtio (hvc0) |
|------|----------------|---------------|
| cp0 | `tcp:127.0.0.1:25500` | `tcp:127.0.0.1:25501` |
| cp1 | `tcp:127.0.0.1:25510` | `tcp:127.0.0.1:25511` |
| cp2 | `tcp:127.0.0.1:25520` | `tcp:127.0.0.1:25521` |
| w3  | `tcp:127.0.0.1:25530` | `tcp:127.0.0.1:25531` |

```bash
socat -,rawer tcp:127.0.0.1:25500    # cp0 serial console
```

## Nix Targets Reference

All targets are Linux-only (QEMU MicroVMs). Run any target with `nix run .#<name>`.

### Network Management

| Target | Sudo | Description |
|--------|:----:|-------------|
| `k8s-check-host` | No | Verify host prerequisites (/dev/net/tun, vhost_net, bridge module) |
| `k8s-network-setup` | **Yes** | Create bridge (k8sbr0), 4 TAP devices, nftables NAT, haproxy LB |
| `k8s-network-teardown` | **Yes** | Remove bridge, TAPs, NAT rules, stop haproxy |

### VM Management

| Target | Sudo | Description |
|--------|:----:|-------------|
| `k8s-start-all` | No | Build and start all 4 VMs (CPs first, then worker). Bootstrap runs on cp0 |
| `k8s-vm-stop` | No | Stop all running VMs (SIGTERM → SIGKILL fallback) |
| `k8s-vm-stop-one` | No | Stop a single VM by name. `--node=cp0\|cp1\|cp2\|w3` |
| `k8s-vm-start-one` | No | Start a single VM by name. `--node=cp0\|cp1\|cp2\|w3` |
| `k8s-vm-wipe` | No | Stop VMs and delete per-node data images (etcd, containerd, kubelet state) |
| `k8s-cluster-rebuild` | No | Wipe + start-all in one command. Full clean rebuild from scratch |
| `k8s-vm-check` | No | List running K8s MicroVM QEMU processes |
| `k8s-vm-ssh` | No | SSH into a node. Default: cp0. Use `--node=cp1` for others |

### Chaos Testing

| Target | Sudo | Description |
|--------|:----:|-------------|
| `k8s-chaos-failover` | No | Loop-kill nodes one at a time; measure per-DB failover recovery time |

### Matrix

| Target | Sudo | Description |
|--------|:----:|-------------|
| `k8s-matrix-register-user` | No | Register a Matrix user via Synapse admin API. `--username=<name> [--admin]` |
| `k8s-matrix-bootstrap-secrets` | No | Generate Matrix tokens + secrets, create `matrix-secrets` K8s Secret. See docs/matrix.md |

### Anubis

| Target | Sudo | Description |
|--------|:----:|-------------|
| `k8s-anubis-bootstrap-secrets` | No | Generate Anubis ED25519 signing key, create `anubis-secrets` K8s Secret in ns=nginx |

### Observability

| Target | Sudo | Description |
|--------|:----:|-------------|
| `k8s-observability-bootstrap-secrets` | No | Create CH users (otel writer, hyperdx reader) + populate K8s Secrets |

### Registry (Zot)

| Target | Sudo | Description |
|--------|:----:|-------------|
| `k8s-registry-bootstrap-secrets` | No | Generate htpasswd for push user + populate TLS Secret from node PKI |
| `k8s-registry-push` | No | Push a Nix-built OCI image (docker-archive tarball) into the in-cluster Zot registry |

### GitOps & Manifests

| Target | Sudo | Description |
|--------|:----:|-------------|
| `k8s-render-manifests` | No | Render Helm charts + Nix manifests to `rendered/` directory. Use `--check` for CI |
| `k8s-manifests` (package) | No | `nix build .#k8s-manifests` — build all rendered YAML to Nix store |

### Certificates & Secrets

| Target | Sudo | Description |
|--------|:----:|-------------|
| `k8s-gen-certs` | No | Copy build-time PKI to `./certs/` for inspection |
| `k8s-gen-secrets` | No | Generate application secrets into `./secrets/`. See [docs/secrets.md](docs/secrets.md) |

### VM Packages

Build individual VM images with `nix build .#<name>`:

| Package | Description |
|---------|-------------|
| `k8s-microvm-cp0` | Control plane 0 (etcd, apiserver, CM, scheduler, kubelet) |
| `k8s-microvm-cp1` | Control plane 1 |
| `k8s-microvm-cp2` | Control plane 2 |
| `k8s-microvm-w3`  | Worker node (kubelet only) |
| `k8s-pki` | Raw PKI store (all certificates) |

### Lifecycle Testing

| Target | Description |
|--------|-------------|
| `k8s-lifecycle-test-cp0` | Per-node test: build → boot → console → SSH → certs → services → k8s → shutdown |
| `k8s-lifecycle-test-cp1` | Same for cp1 |
| `k8s-lifecycle-test-cp2` | Same for cp2 |
| `k8s-lifecycle-test-w3` | Same for w3 |
| `k8s-lifecycle-test-all` | Run all 4 per-node tests sequentially |
| `k8s-cluster-test` | Full cluster integration: etcd quorum, apiserver, node registration |

### Dev Shell

```bash
nix develop
```

Available tools: `kubectl`, `kubernetes-helm`, `cilium-cli`, `hubble`, `argocd`, `step-cli`, `socat`, `expect`, `sshpass`, `jq`, `mariadb`, `sysbench`, `postgresql` (psql), `clickhouse`, `foundationdb` (fdbcli), `bc`, `nftables`, `iproute2`, `curl`, `mkcert`, `openssl`, `apacheHttpd` (htpasswd)

## Bootstrap Sequence

On first boot, a systemd oneshot service (`k8s-gitops-bootstrap`) on cp0 automatically deploys the cluster stack in order:

```
1. Wait for apiserver (https://localhost:6443/livez)
2. Apply base manifests (namespaces, RBAC, CoreDNS)
   └── Wait for CoreDNS rollout
3. Apply Cilium CNI (helm-templated at Nix build time)
   └── Wait for Cilium DaemonSet rollout
4. Create argocd-redis Secret
5. Apply ArgoCD (helm-templated at Nix build time)
   └── Wait for Application CRD + argocd-server rollout
6. Apply all ArgoCD Application CRs
   (cilium, argocd, base, cert-manager, clickhouse, foundationdb,
    matrix, nginx, observability, registry, tidb, postgres)
7. Touch /var/lib/k8s-bootstrap/done (idempotent marker)
```

The bootstrap uses manifests baked into the Nix store (no git fetch needed — CNI isn't up yet when it starts). After day 1, ArgoCD is the source of truth via the git repo.

Watch progress: `nix run .#k8s-vm-ssh -- --node=cp0 journalctl -fu k8s-gitops-bootstrap`

## Rendered Manifests Pattern

This project implements the [rendered manifests pattern](https://akuity.io/blog/the-rendered-manifests-pattern) for GitOps. All Helm charts are rendered via `helm template` at Nix build time into plain YAML — ArgoCD only applies static manifests, with no in-cluster Helm templating.

### How it works

1. **Nix expressions** in `nix/gitops/env/` define each component declaratively
2. **Helm charts** (Cilium, ArgoCD) are pinned by version + SRI hash in `constants.nix` and rendered via `helm template` at build time by `nix/gitops/helm-chart.nix`
3. **Plain YAML components** (ClickHouse, FoundationDB, nginx, base) are defined inline in Nix
4. `nix run .#k8s-render-manifests` builds everything and copies to `rendered/`
5. `rendered/` is committed to git — full audit trail of actual YAML changes
6. **ArgoCD Application CRs** point at `rendered/<component>/` directories using path-source, with `directory.exclude` to skip the Application CR itself

### Pinned Helm Charts

| Chart | Version | App Version |
|-------|---------|-------------|
| Cilium | 1.19.3 | 1.19.3 |
| ArgoCD (argo-cd) | 9.5.0 | v3.3.6 |
| CloudNativePG (CNPG) | 0.28.0 | v1.29.0 |
| OpenTelemetry Collector | 0.140.0 | 0.140.0 |
| ClickStack | 1.1.1 | 2.8.0 |

### Workflow

```bash
# 1. Edit Nix source (e.g. change Cilium values, add a component)
vim nix/gitops/env/cilium.nix

# 2. Render manifests
nix run .#k8s-render-manifests

# 3. Review the actual YAML diff
git diff rendered/

# 4. Commit both source and rendered output
git add nix/gitops/ rendered/
git commit -m "Update cilium Hubble config"

# 5. Verify rendered/ is up to date (CI / pre-commit check)
nix run .#k8s-render-manifests -- --check
```

### Deployed Components

| Component | Type | Description |
|-----------|------|-------------|
| **base** | Plain YAML | Namespaces, RBAC (apiserver→kubelet), CoreDNS (2 replicas) |
| **Cilium** | Helm-rendered | CNI (replaces kube-proxy), dual-stack, Hubble UI/Relay/metrics |
| **ArgoCD** | Helm-rendered | GitOps controller, self-managing via path-source Application |
| **ClickHouse** | Plain YAML | 3 Keeper (Raft) + 2 shards x 2 replicas, ReplicatedMergeTree |
| **FoundationDB** | Plain YAML | 3 coordinators + 4 storage, triple-ssd replication, benchmark |
| **TiDB** | Plain YAML | 3 PD + 4 TiKV + 2 TiDB, MySQL-compatible distributed SQL, sysbench |
| **PostgreSQL (CNPG)** | Helm-rendered + CR | 1 primary + 3 replicas via CloudNativePG operator, auto-failover |
| **nginx + Anubis** | Plain YAML | Hello-world page fronted by [TecharoHQ/Anubis](https://github.com/TecharoHQ/anubis) proof-of-work anti-scraper; exposed at `https://hello.lab.local` |
| **Cilium Ingress** | Helm-rendered (folded into Cilium) | Envoy-based ingress controller, LoadBalancer Service on L2-announced VIP `10.33.33.50` |
| **cert-manager** | Upstream YAML + CRs | `selfsigned-lab` ClusterIssuer (phase 1); stub `letsencrypt-prod-dns01` (phase 2) |
| **Matrix** | Plain YAML + CNPG `Database` CRs | Synapse + Element + hookshot + maubot + mautrix-discord on `matrix.lab.local` |
| **Observability** | Helm-rendered + Plain YAML | OTel Collector DaemonSet + ClickStack UI (HyperDX) + hubble-otel DS + schema-bootstrap Job → `otel` database in existing ClickHouse cluster |
| **Registry (Zot)** | Plain YAML | In-cluster OCI registry on dedicated LB VIP `10.33.33.51`; anonymous pull, htpasswd-gated push |

## Certificate Architecture (PKI)

All certificates are generated at `nix build` time by `certs.nix` and baked directly into VM images. There is no runtime certificate injection — VMs boot with all PKI material already in place at `/var/lib/kubernetes/pki/`.

### Certificate Authorities (3 independent CAs)

The cluster uses three separate CA hierarchies to isolate trust domains:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Certificate Authorities                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────────────┐  │
│  │  k8s-cluster-ca  │  │     etcd-ca      │  │    front-proxy-ca       │  │
│  │  (ca.crt/ca.key) │  │  (etcd-ca.crt/   │  │  (front-proxy-ca.crt/  │  │
│  │                  │  │   etcd-ca.key)   │  │   front-proxy-ca.key)  │  │
│  └────────┬─────────┘  └────────┬─────────┘  └────────────┬───────────┘  │
│           │                     │                          │              │
│  Signs:   │            Signs:   │                 Signs:   │              │
│  ┌────────┴──────────┐ ┌───────┴──────────┐    ┌─────────┴──────────┐   │
│  │ apiserver.crt     │ │ etcd-server.crt  │    │ front-proxy-client │   │
│  │ apiserver-kubelet │ │ etcd-peer.crt    │    │   .crt             │   │
│  │  -client.crt      │ │ apiserver-etcd   │    └────────────────────┘   │
│  │ kubelet-{node}.crt│ │  -client.crt     │                             │
│  │ controller-       │ └──────────────────┘                             │
│  │  manager.crt      │                                                   │
│  │ scheduler.crt     │                                                   │
│  │ admin.crt         │                                                   │
│  └───────────────────┘                                                   │
│                                                                             │
│  + Service Account keypair (sa.key / sa.pub) — RSA 2048, signs JWTs       │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Chain of Trust

```
k8s-cluster-ca (ca.crt)
├── apiserver.crt              API server TLS (serves on :6443)
│   SANs: kubernetes, kubernetes.default, kubernetes.default.svc,
│         kubernetes.default.svc.cluster.local, 10.96.0.1,
│         10.33.33.1 (haproxy VIP), 127.0.0.1, ::1,
│         10.33.33.{10,11,12,13}, fd33:33:33::{10,11,12,13}
├── apiserver-kubelet-client.crt   apiserver → kubelet mTLS client
├── kubelet-cp0.crt            kubelet identity (CN=system:node:k8s-cp0, O=system:nodes)
├── kubelet-cp1.crt            kubelet identity (CN=system:node:k8s-cp1, O=system:nodes)
├── kubelet-cp2.crt            kubelet identity (CN=system:node:k8s-cp2, O=system:nodes)
├── kubelet-w3.crt             kubelet identity (CN=system:node:k8s-w3, O=system:nodes)
├── controller-manager.crt     CN=system:kube-controller-manager
├── scheduler.crt              CN=system:kube-scheduler
└── admin.crt                  CN=kubernetes-admin, O=system:masters (cluster-admin)

etcd-ca (etcd-ca.crt)
├── etcd-server-{cp0,cp1,cp2}.crt   etcd TLS server (per-node)
│   SANs: localhost, 127.0.0.1, ::1, all node IPs
├── etcd-peer-{cp0,cp1,cp2}.crt     etcd peer-to-peer mTLS (per-node)
│   SANs: localhost, 127.0.0.1, ::1, all node IPs
└── apiserver-etcd-client.crt        apiserver → etcd mTLS client

front-proxy-ca (front-proxy-ca.crt)
└── front-proxy-client.crt     aggregation layer (API extension servers)

sa.key / sa.pub (RSA 2048)
└── Used by apiserver to sign and verify ServiceAccount JWTs
```

### Per-Node Certificate Bundles

Each VM receives only the certs it needs, assembled by `mkNodePki` in `certs.nix`:

| File | Control Plane | Worker | Purpose |
|------|:---:|:---:|---------|
| ca.crt, ca.key | Y | Y | Cluster CA (verify + sign) |
| etcd-ca.crt | Y | Y | Verify etcd connections |
| front-proxy-ca.crt | Y | Y | Verify aggregation layer |
| sa.pub, sa.key | Y | Y | ServiceAccount token verify/sign |
| kubelet.crt, kubelet.key | Y | Y | Node identity (per-node CN) |
| kubelet-kubeconfig | Y | Y | kubelet → apiserver auth |
| kubelet-config.yaml | Y | Y | kubelet runtime config |
| apiserver.crt, apiserver.key | Y | - | API server TLS |
| apiserver-kubelet-client.crt/key | Y | - | apiserver → kubelet mTLS |
| apiserver-etcd-client.crt/key | Y | - | apiserver → etcd mTLS |
| front-proxy-ca.key | Y | - | Sign aggregation certs |
| front-proxy-client.crt/key | Y | - | Aggregation layer client |
| etcd-ca.key | Y | - | Sign etcd certs |
| etcd-server.crt/key | Y | - | etcd TLS server (per-node) |
| etcd-peer.crt/key | Y | - | etcd peer mTLS (per-node) |
| controller-manager.crt/key | Y | - | Controller manager identity |
| scheduler.crt/key | Y | - | Scheduler identity |
| admin.crt/key | Y | - | Cluster admin (kubectl) |
| controller-manager-kubeconfig | Y | - | CM → apiserver auth |
| scheduler-kubeconfig | Y | - | Scheduler → apiserver auth |
| admin-kubeconfig | Y | - | Admin → apiserver auth |

**Total: 33 files per control plane, 10 files per worker.**

### How Certs Flow from Build to VM

```
nix build .#k8s-microvm-cp0
        │
        ▼
  ┌─────────────┐     ┌──────────────────┐     ┌─────────────────────┐
  │  certs.nix  │────▶│    pkiStore      │────▶│  mkNodePki          │
  │  (step-cli  │     │  /nix/store/...  │     │  Selects per-node   │
  │   openssl)  │     │  All 50+ certs   │     │  subset (33 or 10)  │
  └─────────────┘     └──────────────────┘     └──────────┬──────────┘
                                                          │
                                                          ▼
                                               ┌─────────────────────┐
                                               │   microvm.nix       │
                                               │   NixOS activation  │
                                               │   script copies     │
                                               │   from /nix/store   │
                                               │   → /var/lib/       │
                                               │   kubernetes/pki/   │
                                               └─────────────────────┘
```

All kubeconfigs point to `https://10.33.33.1:6443` (the haproxy VIP), not to any individual control plane node. This means kubelets and kubectl work through the load balancer for HA.

### Certificate Inspection

```bash
# Copy build-time certs to ./certs/ for inspection
nix run .#k8s-gen-certs

# Inspect a cert
openssl x509 -in ./certs/apiserver.crt -text -noout | grep -A1 "Subject Alternative Name"

# Verify cert chain on a running node
nix run .#k8s-vm-ssh -- --node=cp0 openssl verify \
  -CAfile /var/lib/kubernetes/pki/ca.crt /var/lib/kubernetes/pki/apiserver.crt
```

## API Server High Availability (haproxy)

The cluster uses a host-side haproxy to load-balance the Kubernetes API endpoint across all 3 control plane nodes. This solves the chicken-and-egg problem: kubelets and Cilium need a stable apiserver endpoint before in-cluster service routing exists.

```
                    ┌─────────────────────────────────────────┐
                    │              Host Machine                │
                    │                                         │
  kubectl ──────┐   │   haproxy (10.33.33.1:6443)            │
                │   │     │  TCP mode, round-robin            │
  kubelet ──────┤   │     │  health: TCP check every 5s      │
   (all nodes)  │   │     │  tolerates: 1 CP down            │
                ├───┼────▶│                                   │
  Cilium ───────┤   │     ├──▶ cp0 (10.33.33.10:6443)       │
   agent        │   │     ├──▶ cp1 (10.33.33.11:6443)       │
                │   │     └──▶ cp2 (10.33.33.12:6443)       │
  controller ───┘   │                                         │
   -manager         │    Backend health: check inter 5s       │
                    │    fall 3 (mark down after 3 fails)     │
                    │    rise 2 (mark up after 2 successes)   │
                    └─────────────────────────────────────────┘
```

### HA Behavior

| Scenario | Behavior |
|----------|----------|
| All 3 CPs healthy | Round-robin across cp0, cp1, cp2 |
| 1 CP down | haproxy detects in ~15s (3 x 5s), routes to remaining 2 |
| 2 CPs down | Routes all traffic to surviving CP; etcd still has quorum if 2/3 up |
| etcd quorum lost (2+ CPs down) | Apiserver becomes read-only, writes fail |

Cilium provides in-cluster service load balancing via eBPF, but it can't provide the initial apiserver endpoint because Cilium itself needs apiserver to get its configuration. haproxy on the host bridge runs outside the cluster and is available before any VM boots.

## systemd Service Hardening

All K8s services inside the MicroVMs are hardened with systemd security directives, verified via `systemd-analyze security`. The goal is to apply the principle of least privilege — each service gets only the capabilities and filesystem access it actually needs.

### Security Scores

| Service | Before | After | Rating |
|---------|--------|-------|--------|
| etcd | 9.8 | 1.8 | UNSAFE → OK |
| kube-apiserver | 9.6 | 1.7 | UNSAFE → OK |
| kube-controller-manager | 9.6 | 1.7 | UNSAFE → OK |
| kube-scheduler | 9.6 | 1.7 | UNSAFE → OK |
| kubelet | 9.6 | 5.7 | UNSAFE → MEDIUM |
| containerd | 9.6 | 5.7 | UNSAFE → MEDIUM |

Scores are from `systemd-analyze security` (0 = fully locked down, 10 = no restrictions). Lower is better.

### Control Plane Services (etcd, apiserver, controller-manager, scheduler)

These are network services that read certificates, listen on TCP ports, and talk to each other. They don't need hardware access, kernel module loading, namespace creation, or any Linux capabilities (all ports > 1024). They receive full hardening:

- **Filesystem**: `ProtectSystem=full`, `ProtectHome`, `PrivateTmp`, `PrivateDevices`
- **Kernel**: `ProtectKernelTunables`, `ProtectKernelModules`, `ProtectKernelLogs`, `ProtectControlGroups`
- **Isolation**: `ProtectClock`, `ProtectHostname`, `ProtectProc=invisible`, `ProcSubset=pid`
- **Privileges**: `NoNewPrivileges`, `CapabilityBoundingSet=""` (no capabilities at all)
- **Syscalls**: `SystemCallArchitectures=native`, `SystemCallFilter=@system-service ~@privileged ~@resources`
- **Namespaces**: `RestrictNamespaces` (cannot create any)
- **Network**: `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX` (TCP/UDP/Unix only)
- **Other**: `MemoryDenyWriteExecute`, `LockPersonality`, `RestrictRealtime`, `RestrictSUIDSGID`, `UMask=0077`

### Why kubelet and containerd Score Higher (5.7)

kubelet and containerd are the container runtime layer — they fundamentally require elevated privileges to create and manage containers (cgroups, namespaces, overlay mounts, veth pairs). The 5.7 MEDIUM score represents the inherent privilege floor for any container runtime. Hardening that *is* applied (ProtectHome, ProtectKernelModules, ProtectClock, restricted address families, syscall filtering) still eliminates capabilities and attack surface that container management doesn't need.

```bash
# Check scores on a running node
nix run .#k8s-vm-ssh -- --node=cp0 systemd-analyze security

# Detailed breakdown for a specific service
nix run .#k8s-vm-ssh -- --node=cp0 systemd-analyze security etcd.service
```

## Lifecycle Testing

### Per-Node Tests

Each per-node test runs a VM in isolation through 9 phases with millisecond timing:

```bash
nix run .#k8s-lifecycle-test-cp0    # Single node
nix run .#k8s-lifecycle-test-all    # All 4 nodes sequentially
```

| Phase | Name | What it checks |
|-------|------|----------------|
| 0 | Build | `nix build` succeeds |
| 1 | Start | QEMU process starts |
| 2/2b | Console | Serial (ttyS0) and virtio (hvc0) respond |
| 3 | SSH | SSH is reachable |
| 4 | Certs | PKI files present, CA chains validate (33 on CP, 10 on worker) |
| 5 | Services | systemd services active (containerd) |
| 6 | K8s Health | etcd + apiserver (requires cluster for quorum) |
| 7/8 | Shutdown | Clean poweroff and process exit |

### Cluster Test

The cluster test boots all 4 VMs together and verifies the K8s control plane forms correctly:

```bash
nix run .#k8s-cluster-test
```

| Phase | Name | Timeout | What it checks |
|-------|------|---------|----------------|
| C0 | Build All VMs | 900s | `nix build` for all 4 nodes |
| C1 | Start All VMs | 30s | Launch all 4 VMs, verify QEMU processes |
| C2 | SSH Ready | 90s | SSH connectivity to all 4 nodes |
| C3 | Etcd Quorum | 120s | `etcdctl endpoint health` on all 3 CPs + 3-member quorum |
| C4 | API Server Health | 120s | `/healthz` returns "ok" on all 3 CPs |
| C5 | Node Registration | 180s | `kubectl get nodes` shows 4 nodes registered |
| C6 | Shutdown All | 60s | Graceful poweroff all VMs |

## File Structure

```
flake.nix                        # Orchestrator — imports, mkK8sNode, packages, apps, devShell
nix/
├── constants.nix                # IPs, MACs, ports, CIDRs, helm chart pins, timeouts
├── nodes.nix                    # Node definitions (cp0, cp1, cp2, w3) with role + services
├── microvm.nix                  # mkK8sNode parametric generator (TAP, dual serial, 9p store)
├── k8s-module.nix               # NixOS module: etcd, apiserver, kubelet, containerd (v3 config)
├── monitoring-module.nix        # NixOS module: Prometheus, Grafana, scrape targets
├── gitops-bootstrap-module.nix  # NixOS module: first-boot oneshot (Cilium→CoreDNS→ArgoCD→Apps)
├── network-setup.nix            # Bridge + TAP + NAT + haproxy LB setup/teardown
├── certs.nix                    # Build-time PKI: 3 CAs + per-component certs, baked into VMs
├── secrets-gen.nix              # Offline secret generation (→ ./secrets/). See docs/secrets.md
├── secrets.nix                  # Build-time: reads ./secrets/, emits K8s Secret JSON manifests
├── cert-inject.nix              # Legacy: expect-driven cert transfer over virtio (manual use)
├── microvm-scripts.nix          # VM management: check, stop, ssh, start-all, wipe, rebuild
├── chaos-scripts.nix            # Chaos failover test runner (k8s-chaos-failover)
├── matrix-scripts.nix           # Matrix user registration & secret bootstrap
├── anubis-scripts.nix           # Anubis ED25519 key bootstrap
├── observability-scripts.nix    # Observability CH user + secret bootstrap
├── registry-scripts.nix         # In-cluster Zot registry push + secret bootstrap
├── render-script.nix            # Rendered manifests → nix run .#k8s-render-manifests
├── shell.nix                    # devShell: kubectl, helm, cilium-cli, hubble, argocd, ...
├── test-lib.nix                 # Shared bash helpers (color, timing, assertions)
├── images/
│   └── hubble-otel.nix          # hubble-otel OCI image builder (archived cilium/hubble-otel)
├── lifecycle/
│   ├── default.nix              # Lifecycle test orchestrator (per-node + test-all + cluster)
│   ├── lib.nix                  # Script generators (process, console, SSH, timing helpers)
│   ├── constants.nix            # Per-node services, health checks, timeouts
│   ├── k8s-checks.nix           # K8s verification (etcd, apiserver, node registration)
│   └── scripts/
│       ├── vm-lib.exp           # Shared expect library (login, run_cmd, retry)
│       ├── vm-cert-inject.exp   # Cert transfer over virtio console
│       └── vm-k8s-verify.exp    # K8s service verification via console
└── gitops/
    ├── default.nix              # Manifest aggregator (handles both inline YAML and helm source)
    ├── helm-chart.nix           # Generic helm template helper (fetchurl + extract + render)
    ├── env/
    │   ├── base.nix             # Namespaces, RBAC, CoreDNS
    │   ├── argocd.nix           # ArgoCD Helm chart (v9.5.0) + self-managing Application
    │   ├── cilium.nix           # Cilium Helm chart (v1.19.3) + Hubble + Application
    │   ├── clickhouse.nix       # ClickHouse 3 Keeper + 2x2 shards + Application
    │   ├── foundationdb.nix     # FoundationDB 3 coord + 4 storage + benchmark + Application
    │   ├── nginx.nix            # Nginx hello-world + Application
    │   ├── tidb.nix             # TiDB 3 PD + 4 TiKV + 2 TiDB + sysbench + Application
    │   ├── postgres.nix         # CNPG operator (helm) + Cluster CR (1 primary + 3 replicas) + Application
    │   ├── cert-manager.nix     # cert-manager + selfsigned-lab ClusterIssuer (phase 1) + stub LE DNS-01 (phase 2)
    │   ├── matrix.nix           # Matrix stack aggregator: Synapse + Element + hookshot + maubot + mautrix-discord
    │   ├── observability.nix    # OTel Collector (helm) + ClickStack UI (helm) + hubble-otel DS + schema-bootstrap Job
    │   └── registry.nix         # In-cluster Zot OCI registry + dedicated LB VIP + containerd mirror config
    └── matrix/
        ├── shared.nix           # CNPG Database CRs, matrix-tls Certificate, single Ingress (4 hosts)
        ├── synapse.nix          # Synapse Deployment + ConfigMap + PVC + Services (ClusterIP + admin NodePort)
        ├── element.nix          # Element Web Deployment + Service
        ├── hookshot.nix         # matrix-hookshot Deployment + registration/config ConfigMaps + Service
        ├── maubot.nix           # maubot Deployment + plugins PVC + config ConfigMap + Service
        └── mautrix-discord.nix  # mautrix-discord Deployment + registration/config ConfigMaps + Service
docs/
├── observability.md             # Observability subsystem architecture (OTel + ClickStack)
├── matrix.md                    # Matrix stack architecture and bootstrapping
└── secrets.md                   # Secrets management design (offline gen → auto-injection)
rendered/                        # Committed rendered manifests (git-tracked)
├── argocd/                      # ArgoCD install.yaml (helm-rendered), values, Application CR
├── base/                        # Namespaces, RBAC, CoreDNS
├── cilium/                      # Cilium install.yaml (helm-rendered), values, Application CR
├── clickhouse/                  # ClickHouse manifests
├── fdb/                         # FoundationDB manifests + benchmark
├── nginx/                       # Nginx manifests
├── tidb/                        # TiDB PD + TiKV + TiDB + sysbench manifests
├── postgres/                    # local-path-provisioner, CNPG operator (helm-rendered), Cluster CR, NodePort services
├── cert-manager/                # Upstream install + selfsigned-lab ClusterIssuer chain + Application
├── matrix/                      # Synapse, Element, hookshot, maubot, mautrix-discord, Ingress, Certificate, Databases
├── observability/               # OTel Collector, ClickStack UI, hubble-otel, schema-bootstrap Job
└── registry/                    # Zot registry, LB VIP pool, htpasswd + TLS Secrets
```

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| Helm template at Nix build time | ArgoCD applies plain YAML — no in-cluster Helm, no chart pulls |
| Bootstrap systemd oneshot on cp0 | Bootstraps Cilium→CoreDNS→ArgoCD→Apps in order; baked into Nix store (no git fetch before CNI is up) |
| CoreDNS in base manifests | Required for in-cluster DNS (service discovery, hubble-relay peer resolution) |
| containerd v3 config | Matches containerd 2.x native format (split CRI plugin paths) |
| TAP-only networking | Nodes must communicate for etcd peering and kubelet registration |
| 3 CP + haproxy LB | 3-node etcd quorum tolerates 1 CP failure; haproxy on bridge IP provides apiserver HA |
| Host-side haproxy (not Cilium) | Apiserver endpoint must exist before Cilium boots (chicken-and-egg) |
| Build-time PKI | Certs baked into VM images via Nix — no runtime injection, fully reproducible |
| Offline secrets pre-generation | `k8s-gen-secrets` generates random material once; Nix builds K8s Secret manifests; bootstrap applies them. Zero manual steps. See [docs/secrets.md](docs/secrets.md) |
| 3 separate CAs | Isolates trust domains: cluster, etcd, and front-proxy (K8s best practice) |
| Cilium replaces kube-proxy | eBPF-based, no iptables overhead, native dual-stack |
| Pinned chart hashes | Reproducible builds — chart tarballs fetched with SRI hash verification |
| `directory.exclude` on Application CRs | Prevents ArgoCD from self-applying its own Application CR file |
| Wipe/rebuild scripts | Easy to tear down and recreate the cluster from scratch for testing |
| systemd hardening | Control plane: CapabilityBoundingSet="" (score 1.7); kubelet/containerd: minimum caps for container lifecycle (score 5.7) |
| 8GB CPs, 6GB worker | Headroom for ArgoCD, ClickHouse, FDB alongside K8s services |

## Teardown

```bash
# Stop all VMs
nix run .#k8s-vm-stop

# Remove network infrastructure
sudo nix run .#k8s-network-teardown

# Full cleanup (VMs + data images)
nix run .#k8s-vm-wipe
```
