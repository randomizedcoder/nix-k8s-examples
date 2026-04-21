# Cluster Observability

Comprehensive visibility — **logs, traces, metrics, and Cilium/Hubble network
flows** — unified in a single queryable backend and a single UI.

This document is the design for the observability subsystem. Implementation
lands in follow-up PRs; this file is the source of truth for what those PRs
must produce and why.

## Why ClickStack

The cluster already runs a 4-node HA ClickHouse (2 shards × 2 replicas + 3
Keeper) as a first-class component. ClickHouse is also the OLAP backend of
[ClickStack](https://clickhouse.com/docs/use-cases/observability/clickstack),
ClickHouse's reference observability stack (ClickHouse + ClickStack UI +
OpenTelemetry Collector). Using ClickStack here means:

- One database engine for OLTP (Postgres/TiDB), distributed KV (FoundationDB),
  and **all observability data** — no new storage system to operate.
- The existing `ch4` cluster's ReplicatedMergeTree + Keeper replication gives
  observability storage HA for free.
- Upstream [OpenTelemetry Collector ClickHouse
  exporter](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/exporter/clickhouseexporter)
  ships schema and dictionary DDL that the ClickStack UI
  ([HyperDX](https://github.com/hyperdxio)) consumes natively.
- One agent stack (OTel Collector) handles logs, metrics, **and** traces —
  no separate Fluent Bit / Promtail / Jaeger / Tempo deployment.
- The OTel Collector's OTLP gRPC receivers/exporters support Unix domain
  sockets (`endpoint: unix:///…`), so the ingest fan-in inside a node
  runs on UDS rather than TCP. The only TCP hop left inside a node is
  the collector → local ClickHouse write, and that's pinned to
  `127.0.0.1:9000` (loopback, no NIC) by co-locating the collector and
  the CH pod on the same node (see topology section).
- ClickHouse itself doesn't listen on UDS (upstream issue
  [#22260](https://github.com/ClickHouse/ClickHouse/issues/22260) was
  closed *not planned*). The design accepts this and targets "UDS where
  the component supports it, loopback-TCP otherwise" rather than
  forking the exporter or tunnelling via socat sidecars (both of which
  give ~zero speedup over loopback TCP for realistic OTLP batch sizes).

## Stack

| Layer | Component | Purpose |
|---|---|---|
| Collector (per-node) | **OpenTelemetry Collector** DaemonSet — single tier | Tails pod stdout/stderr (`filelog`), collects `k8s_events`, `kubeletstats`, `hostmetrics`; also receives OTLP from apps and from the on-node `hubble-otel` sidecar **over Unix domain sockets**; receives `prometheusremotewrite` over loopback HTTP from cp0's Prometheus; `memory_limiter` + `batch` + `tail_sampling` + `transform`; exports to the **co-located** ClickHouse pod over loopback TCP native protocol (`127.0.0.1:9000`). One process per node — no separate agent/gateway split; see [§ Topology: single-tier DaemonSet with UDS ingress](#topology-single-tier-daemonset-with-uds-ingress) for why. |
| Storage | **ClickHouse** (existing `ch4` cluster) | New database `otel`; `ReplicatedMergeTree` tables for logs, traces, metrics, hubble_flows. Distributed tables on top for fan-in. Already runs as a 4-replica StatefulSet with pod-anti-affinity → exactly one CH pod per node, which is what makes the collector's co-location strategy possible. |
| UI | **ClickStack UI** (upstream project: HyperDX) | Unified search / dashboards for all signal types. Served at `clickstack.lab.local` via Cilium Ingress. |
| UI state | **MongoDB** (single-replica StatefulSet, emptyDir) | ClickStack UI's own dashboard/user config. Phase-2: PVC + replica set via MCK operator. |
| Hubble bridge | **hubble-otel** DaemonSet | Connects directly to the **node-local Hubble agent Unix socket** at `/var/run/cilium/hubble.sock` (bypasses `hubble-relay` entirely for ingest), emits OTLP over UDS to the local OTel collector. |
| Prometheus bridge | NixOS `services.prometheus.remoteWrite` → collector's `prometheusremotewrite` receiver on cp0 | Kept on TCP loopback (HTTP remote_write has no UDS). Only cp0 runs Prometheus, so this hop only exists on one node. |
| Schema bootstrap | One-shot Kubernetes **Job** (ArgoCD sync-wave 1) | Runs the `clickhouseexporter` canonical DDL against the existing CH cluster; creates DB `otel` + all ReplicatedMergeTree/Distributed tables idempotently. |
| Ingress | Cilium Ingress (Envoy) on L2-announced VIP `10.33.33.50` | Same VIP and `ingressClassName: cilium` used by Matrix and hello-world. TLS from the `selfsigned-lab` ClusterIssuer. |

## Architecture

All hops inside a single node are either **Unix domain sockets** or
**loopback TCP** — no physical NIC involvement. Cross-node traffic only
appears at two points: (1) CH's own ReplicatedMergeTree replication between
the four CH pods (managed by CH + Keeper, already part of the existing
`ch4` cluster), and (2) the Cilium Ingress → ClickStack UI browser path.

```
 ┌────────────────────────── one node (× 4) ──────────────────────────┐
 │                                                                    │
 │  /var/log/pods/** ────┐                                            │
 │                       │ file reads                                 │
 │                       ▼                                            │
 │  ┌──────────────────────────────────────────────────────────────┐  │
 │  │ OTel Collector (DaemonSet — single tier)                     │  │
 │  │   receivers:                                                 │  │
 │  │     filelog          (local files)                           │  │
 │  │     k8s_events       (leader-elected, one DS replica)        │  │
 │  │     kubeletstats     (node kubelet, loopback HTTPS)          │  │
 │  │     hostmetrics      (procfs / sysfs)                        │  │
 │  │     otlp (grpc):                                             │  │
 │  │        • endpoint: unix:///var/run/otel/collector.sock       │  │
 │  │          ← app pods mount this hostPath socket               │  │
 │  │          ← hubble-otel DS writes here                        │  │
 │  │        • endpoint: 127.0.0.1:4317  (loopback fallback)       │  │
 │  │     prometheusremotewrite (cp0 only, loopback HTTP)          │  │
 │  │   processors: memory_limiter, k8sattributes,                 │  │
 │  │               tail_sampling, batch, transform                │  │
 │  │   exporters: clickhouse (tcp://127.0.0.1:9000)  ────────┐    │  │
 │  └──────────────────────────────────────────────────────────┼───┘  │
 │      ▲                ▲                ▲                   │      │
 │      │ UDS            │ UDS            │ HTTP loopback     │ TCP  │
 │      │ /var/run/otel  │ (same socket)  │ (cp0 only)        │ lo   │
 │      │ /collector.sock│                │                   │      │
 │  ┌───┴────────────┐  ┌┴──────────────┐  ┌┴────────────┐    │      │
 │  │ App pods       │  │ hubble-otel DS│  │ NixOS Prom  │    │      │
 │  │ OTEL_EXPORTER  │  │ reads         │  │ remote_write│    │      │
 │  │ _OTLP_ENDPOINT │  │ /var/run/     │  │ (cp0 only)  │    │      │
 │  │ = unix:///…    │  │  cilium/      │  └─────────────┘    │      │
 │  └────────────────┘  │  hubble.sock  │                     │      │
 │                      │ (UDS in)      │                     │      │
 │                      └───────────────┘                     │      │
 │                                                            │      │
 │  ┌─────────────────────────────────────────────────────────▼───┐  │
 │  │ ClickHouse pod (1 per node, co-located via nodeAffinity)    │  │
 │  │   listens: 0.0.0.0:9000 native, :8123 http                  │  │
 │  │   collector writes here via 127.0.0.1:9000 (lo, not NIC)    │  │
 │  │   tables: otel_logs, otel_traces, otel_metrics_*,           │  │
 │  │           hubble_flows   (local ReplicatedMergeTree)        │  │
 │  │           *_dist         (Distributed wrappers)             │  │
 │  └────────────────────────────┬────────────────────────────────┘  │
 │                               │                                    │
 └───────────────────────────────┼────────────────────────────────────┘
                                 │ CH ReplicatedMergeTree replication
                                 │ (cross-node TCP via Keeper — existing,
                                 │  unchanged)
                                 ▼
                        ┌─────────────────────┐
                        │ ClickStack UI       │
                        │ (HyperDX)           │
                        │ clickstack.lab.local│
                        │ via Cilium Ingress  │
                        │ VIP 10.33.33.50     │
                        │ state: MongoDB STS  │
                        └─────────────────────┘
```

### Topology: single-tier DaemonSet with UDS ingress

Why merge the traditional "agent DS + central gateway Deployment" into one
DaemonSet per node:

1. **Eliminates the agent→gateway TCP hop.** With a two-tier design that
   hop is TCP over the pod network (kube-proxy or Cilium eBPF); merging
   turns it into zero hops.
2. **Unlocks UDS ingress from app pods and `hubble-otel`.** A hostPath
   socket under `/var/run/otel/collector.sock` on each node is mountable
   read-write by the collector (creates it) and read-write by producers
   (app pods, `hubble-otel`). This is the big perf win — OTLP SDKs and
   `hubble-otel` already support `unix://` endpoints natively.
3. **Co-locates the collector with a CH pod on the same node.** The
   existing `ch4` StatefulSet has `requiredDuringScheduling` pod
   anti-affinity, so there is exactly one CH pod per node. A matching
   `nodeAffinity` (or just the fact that the collector DS runs on every
   node CH runs on) means the collector's `clickhouseexporter` always has
   a same-node CH target at `127.0.0.1:9000`. That's loopback — `lo`
   interface, no NIC, kernel skb shortcut. Not UDS-fast, but the best
   available given CH's lack of a UDS listener (see
   [ClickHouse/ClickHouse#22260](https://github.com/ClickHouse/ClickHouse/issues/22260)).
4. **Better failure isolation.** A crashed collector affects one node's
   telemetry for one restart cycle, not every signal type cluster-wide.
5. **Trade-off accepted: per-node tail sampling.** Spans of a distributed
   trace can arrive at different nodes' collectors, so tail-sampling
   decisions are made on partial views. Acceptable for Phase-1 lab
   (most lab traces are single-node or very short); Phase-2 can add a
   thin `loadbalancingexporter` tier that routes by `trace_id` to a
   single collector before tail-sampling, if trace completeness matters.

## Signal-by-signal data flow

All ingress hops land on the **node-local** OTel Collector DS. "Local
collector" below means the collector pod running on the same node as the
data source.

1. **Pod / container logs.** Local collector's `filelog` receiver tails
   `/var/log/pods/*/*/*.log` (hostPath mount), parses CRI format, enriches
   each record with pod name / namespace / labels / node via the
   `k8sattributes` processor, and writes directly to the co-located CH
   pod at `tcp://127.0.0.1:9000` (loopback, `lo` interface) →
   `otel.otel_logs_dist`. **No TCP socket setup between producer and
   collector — it's a file read.**
2. **Kubernetes events.** `k8s_events` receiver on **one** DS replica
   (leader-elected via the collector's singleton flag) ingests the Events
   API stream → local CH → `otel.otel_logs_dist` with `event.type=k8s`.
3. **Host / node metrics.** Local collector's `hostmetrics` +
   `kubeletstats` receivers (CPU, memory, disk, network, container cgroup
   stats) → local CH → `otel.otel_metrics_*`. Scrape interval 15 s,
   matching the existing Prometheus `scrape_interval`.
4. **Application traces.** Apps mount the node's
   `/var/run/otel/collector.sock` hostPath UDS into their pod and set
   `OTEL_EXPORTER_OTLP_ENDPOINT=unix:///var/run/otel/collector.sock` on
   their container. The local collector tail-samples (100 % of traces
   containing a span with `status.code = ERROR` plus 10 % baseline of
   successful traces) and writes to `otel.otel_traces_dist`. A loopback
   TCP receiver (`127.0.0.1:4317`) is also exposed for pods that can't
   use hostPath (e.g. strict PSA profiles); this is opt-out, not the
   default.
5. **Existing Prometheus targets (node / Cilium / Hubble / operator).**
   `nix/monitoring-module.nix` is amended with a `remote_write` block
   pointing at `http://127.0.0.1:<localCollectorNodePort>/api/v1/write`
   on cp0 — the cp0 collector's `prometheusremotewrite` receiver. Stays
   on TCP loopback because HTTP remote_write has no UDS transport. Only
   cp0 runs Prometheus, so this hop only exists on one node. Prometheus
   keeps its local TSDB for Grafana's legacy dashboards; ClickStack UI
   becomes the primary read path via ClickHouse.
6. **Cilium Hubble flows.** `hubble-otel` runs as a DaemonSet mounting the
   node-local Cilium runtime directory (`/var/run/cilium`) hostPath and
   connects directly to the Hubble **agent** UDS at
   `/var/run/cilium/hubble.sock` — bypassing `hubble-relay` entirely for
   the ingest path. It translates each flow record into an OTLP log
   (resource attributes for source/dest identity, verdict, L4 protocol,
   and when present L7 HTTP/DNS) and emits to the local collector over
   `/var/run/otel/collector.sock`. Lands in `otel.hubble_flows` (or
   `otel_logs` with `scope=hubble` — decided at schema-bootstrap time
   based on the cardinality we see). L3/L4/L7 visibility end up side by
   side with pod logs and traces in the UI — with **two UDS hops and
   one loopback-TCP hop to CH, zero NIC traffic for same-node flows.**

## ClickHouse schema strategy

The existing `rendered/clickhouse/` module is **not modified** beyond what
the bootstrap Job does on the data plane.

- **New database only:** `otel` — created on cluster via
  `CREATE DATABASE otel ON CLUSTER ch4`.
- **Local tables:** `ReplicatedMergeTree(
  '/clickhouse/tables/{shard}/otel_<name>', '{replica}' )` — reuses the
  existing `{shard}` / `{replica}` macros defined by
  `clickhouse/configmap-server.yaml` → `init-macros.sh`. No new Keeper
  paths, no config changes on the CH pods.
- **Distributed tables:** one per signal type (`otel_logs_dist`,
  `otel_traces_dist`, `otel_metrics_*_dist`, `hubble_flows_dist`) sitting on
  top of the local replicated tables. The OTel gateway writes to `_dist`;
  CH handles shard/replica placement.
- **DDL source:** upstream `clickhouseexporter` canonical schema (tracked
  by the exporter version pinned in `constants.nix`). We do **not** hand-
  roll the schema — bumping the exporter version + re-running the bootstrap
  Job migrates it.
- **TTL (Phase-1 defaults, configurable in `constants.nix`):**

  | Signal | TTL | Rationale |
  |---|---|---|
  | `otel_logs` | 7 d | Fits lab disk; long enough to investigate last-week incidents. |
  | `otel_traces` | 3 d | Traces are big; sampling + short TTL keeps storage bounded. |
  | `otel_metrics_*` | 30 d | Cheap rows; matches typical Prometheus retention. |
  | `hubble_flows` | 2 d | Highest cardinality (per-flow records); keep tight. |

- **User / credentials:** dedicated CH user `otel` with `INSERT` on
  `otel.*`; ClickStack UI uses a read-only `hyperdx` user with `SELECT` on
  `otel.*`. Passwords created by a `k8s-observability-bootstrap-secrets`
  helper (same pattern as the Matrix bootstrap script).

## Phase 1 (lab) vs Phase 2 (public / production)

Phase 1 is what this design specifies. Phase 2 is documented as toggles.

| Aspect | Phase 1 (now) | Phase 2 (future) |
|---|---|---|
| CH backend | Existing `ch4` cluster, `emptyDir` volumes | PVC-backed CH; consider a second CH cluster dedicated to observability if cardinality demands it |
| MongoDB | Single replica, emptyDir | Replica set, PVC, MCK operator |
| ClickStack UI auth | Local admin (bootstrapped password) | OIDC via the same provider used by ArgoCD |
| TLS | `selfsigned-lab` ClusterIssuer | `letsencrypt-prod-dns01` (already stubbed in cert-manager) |
| Ingress VIP | L2-announced `10.33.33.50` | BGP-announced, same VIP, same Service, same Ingress — no manifest change |
| Retention | 7 d logs / 3 d traces / 30 d metrics / 2 d flows | Tiered storage (hot local, cold S3) via CH `storage_policy` |
| Sampling | Tail 100 % errors + 10 % baseline | Per-service sample budgets, head-sampling upstream in app SDKs |
| Secrets | Plain K8s Secrets | External secret store (Vault / SOPS) |
| Prometheus | Kept as secondary UI; single scrape path feeds both local TSDB and OTel gateway | Optional retirement of Grafana if all dashboards migrate to ClickStack UI |

## Integration with existing patterns

- **Rendered-manifests.** A new `nix/gitops/env/observability.nix` exports
  all manifests via the existing aggregation in `nix/gitops/default.nix`.
  Helm charts (`opentelemetry-collector`, `hyperdx`) are pinned in
  `constants.nix` and rendered at Nix build time via the existing
  `renderChart` helper in `nix/gitops/helm-chart.nix`. Output lives in
  `rendered/observability/`; ArgoCD syncs it like every other service.
- **ArgoCD sync order.** The `observability` Application is wave 0; the
  schema-bootstrap Job carries `argocd.argoproj.io/sync-wave: "1"` so it
  runs after ClickHouse is up but before the collector DS and `hubble-otel`
  DS start writing. The DSes themselves are wave 2.
- **Collector scheduling (co-location with CH).** The collector DS uses
  the same `tolerations` and a `nodeAffinity` `matchExpressions` rule that
  matches the 4 nodes the CH StatefulSet runs on (all 4 in Phase-1 — i.e.
  a plain DS with no node selector works today; the constraint is
  documented so that when more nodes join in Phase-2, the collector only
  lands on nodes that have a CH pod).
- **Shared UDS hostPath.** Each node gets `/var/run/otel/` (mode 0770,
  `hostPath` type `DirectoryOrCreate`). The collector DS mounts it
  read-write and creates `collector.sock`. App pods that opt into
  UDS-based OTLP export mount it read-only. `hubble-otel` mounts both
  `/var/run/otel/` (rw, for its output socket connection) and
  `/var/run/cilium/` (ro, for Hubble's agent socket).
- **Prometheus bridge.** `nix/monitoring-module.nix` gains a `remoteWrite`
  block targeting the cp0-local collector at `127.0.0.1:<nodePort>`; all
  existing `scrapeConfigs` (node, prometheus, cilium-agent, hubble,
  cilium-operator) are unchanged.
- **Ingress.** Single Ingress `clickstack.lab.local` via
  `ingressClassName: cilium`, TLS Certificate referencing
  `selfsigned-lab`. The dev host's `/etc/hosts` line gets `clickstack.lab.local`
  appended to the existing VIP mapping.

## Access from the dev host

1. Extend `/etc/hosts`:

   ```
   10.33.33.50 matrix.lab.local element.lab.local hookshot.lab.local maubot.lab.local hello.lab.local clickstack.lab.local
   ```

2. Trust the lab CA once (same one used for Matrix / hello-world):

   ```bash
   kubectl -n cert-manager get secret selfsigned-lab-ca \
     -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/lab-ca.pem
   ```

3. Bootstrap observability secrets once per cluster (CH passwords,
   ClickStack UI admin password):

   ```bash
   nix run .#k8s-observability-bootstrap-secrets
   ```

4. Browse to <https://clickstack.lab.local> and log in with the admin
   password printed by the bootstrap script.

## Resource budget (Phase 1)

Rough caps documented here and enforced by K8s `resources` blocks; numbers
go into `constants.nix` alongside the chart pins. The single-tier DS
absorbs what the two-tier design split between agent and gateway, so its
per-node footprint is slightly higher than a pure agent, but there is no
separate gateway Deployment.

| Component | Replicas | Requests (each) | Limits (each) |
|---|---|---|---|
| OTel Collector (DS, single-tier) | 4 (one/node) | 200 m CPU / 256 Mi | 500 m / 512 Mi |
| hubble-otel (DS) | 4 (one/node) | 50 m / 64 Mi | 200 m / 128 Mi |
| ClickStack UI | 1 | 100 m / 256 Mi | 500 m / 512 Mi |
| MongoDB | 1 | 100 m / 128 Mi | 300 m / 256 Mi |

Cluster-wide this adds up to roughly 1.2 CPU / 1.7 GiB requested — fits
inside the existing MicroVM budget. Host `hostPath` usage:
`/var/run/otel/` (socket only, ~ 0 bytes), `/var/log/pods/` (read-only).

## Known limitations / explicit non-goals (Phase 1)

- **ClickHouse has no UDS listener.** Last hop into CH is loopback TCP
  (`127.0.0.1:9000`). Upstream issue
  [ClickHouse/ClickHouse#22260](https://github.com/ClickHouse/ClickHouse/issues/22260)
  tracks this; the design will adopt UDS to CH if/when it lands.
- **Per-node tail sampling for traces.** Spans of a cross-node trace land
  on different nodes' collectors. Phase-1 accepts partial-view sampling;
  Phase-2 can add a `loadbalancingexporter` tier keyed on `trace_id`.
- **No ClickHouse Operator migration.** The existing hand-rolled
  StatefulSet stays. Migrating to operator-managed CH is a separate design.
- **No auto-instrumentation operator.** Apps opt in to traces manually via
  `OTEL_EXPORTER_OTLP_ENDPOINT` env vars **and** the shared UDS hostPath
  mount. Adding the OpenTelemetry Operator + CRDs is a Phase-2 option.
- **MongoDB is single-replica emptyDir.** Losing its pod loses ClickStack
  UI dashboards / saved searches (not the observability data itself —
  that's in ClickHouse and survives). Acceptable for a lab.
- **No long-term cold storage.** All data expires under the Phase-1 TTLs.
  S3 tiering via `storage_policy` is a Phase-2 change.
- **Grafana is not retired.** Kept as a secondary UI for the existing
  rfmoz Node Exporter Full dashboard and any future Prometheus-native
  dashboards contributors want to add.
- **MongoDB operator not used.** The ClickStack helm chart's default MCK
  operator is disabled to avoid dragging in a second operator for one pod.

## Verification

After implementation lands:

```bash
# 1. Render check — no drift, rendered/observability/ regenerates cleanly.
nix run .#k8s-render-manifests -- --check

# 2. ArgoCD sync status.
nix run .#k8s-vm-ssh -- --node=cp0 kubectl -n argocd get application observability
# → SYNC STATUS=Synced  HEALTH STATUS=Healthy

# 3. Schema created in the existing CH cluster.
nix run .#k8s-vm-ssh -- --node=cp0 \
  "KUBECONFIG=/var/lib/kubernetes/pki/admin-kubeconfig kubectl -n clickhouse exec clickhouse-0 -- \
     clickhouse-client -q 'SHOW DATABASES'"           # → includes 'otel'
# → SHOW TABLES FROM otel lists otel_logs, otel_traces, otel_metrics_*, hubble_flows
#    plus their _dist Distributed counterparts.

# 4. Pods healthy.
kubectl -n observability get pods
# → otel-collector-* (DS, 1 per node), hubble-otel-* (DS, 1 per node),
#   clickstack-ui-*, mongodb-0

# 5. UDS sockets present on every node.
nix run .#k8s-vm-ssh -- --node=cp0 "ls -l /var/run/otel/"
# → srw-rw---- collector.sock  (socket, not file)

# 6. Collector → CH is loopback, not NIC. On any node:
nix run .#k8s-vm-ssh -- --node=cp0 \
  "ss -tn dst 127.0.0.1:9000 | head"
# → ESTAB entries from the collector pod to the local CH pod.

# 7. Logs flowing. Search 'service.name:hello-world' in ClickStack UI;
#    see fresh stdout from the Anubis-fronted hello-world pod within ~15 s.

# 8. Traces flowing via UDS. Run a demo OTLP client inside a pod that
#    mounts /var/run/otel/collector.sock and export with
#    OTEL_EXPORTER_OTLP_ENDPOINT=unix:///var/run/otel/collector.sock;
#    confirm the trace appears in ClickStack UI.

# 9. Prometheus bridge. Query node_cpu_seconds_total in ClickStack UI —
#    confirms Prom → (loopback HTTP) → OTel → (loopback TCP) → CH path.

# 10. Hubble flows via UDS. Generate cross-pod traffic; confirm rows in
#     otel.hubble_flows and live flows in ClickStack UI's flow view.
#     Verify hubble-otel is talking to the Hubble agent UDS:
nix run .#k8s-vm-ssh -- --node=cp0 \
  "ls -l /var/run/cilium/hubble.sock"
# → socket exists; hubble-otel pod has it bind-mounted.

# 11. Chaos parity. Run k8s-chaos-failover and confirm observability
#     survives cp0 reboot (collector DS on other nodes keeps writing to
#     their local CH; no data loss after CH replicas catch up).
```

## File layout (target — implementation PR)

```
docs/observability.md                            This design document.
nix/gitops/env/observability.nix                 Aggregator: OTel Collector DS helm render
                                                 (single tier, UDS+loopback config),
                                                 hubble-otel DS, ClickStack UI render,
                                                 MongoDB STS, schema bootstrap Job, Ingress,
                                                 ArgoCD Application.
nix/constants.nix                                New observability.* block: namespace, chart pins,
                                                 UI host, retention TTLs, resource budgets,
                                                 udsHostPath = "/var/run/otel".
nix/monitoring-module.nix                        Add remoteWrite → cp0-local collector on
                                                 127.0.0.1:<nodePort>; keep scrapeConfigs as is.
nix/observability-scripts.nix                    k8s-observability-bootstrap-secrets helper (same
                                                 pattern as nix/matrix-scripts.nix).
rendered/observability/                          Generated YAML — committed, synced by ArgoCD.
README.md                                        "Observability" entry in Services & Access,
                                                 pointing here.
```

## Future extensions

Captured so they don't get lost:

- OpenTelemetry Operator + auto-instrumentation CRDs so apps get traces
  without code changes.
- eBPF-based profiling (Parca / Pyroscope → CH) as a fourth signal type.
- Alerting: either keep Prometheus Alertmanager wired to the existing
  scrape path, or add ClickHouse-native alerting via ClickStack UI when
  that feature stabilises.
- Migrating ClickHouse to operator-managed (kube-ch-operator) — unifies
  with ClickStack's upstream default and enables the bundled helm chart
  without customisation.
- MCK-managed MongoDB replica set for ClickStack UI state durability.
- S3 cold tier via CH `storage_policy` for multi-month log/trace retention.
- Chaos-test extension: assert zero log-loss during rolling CH restarts and
  gateway pod deletions.
