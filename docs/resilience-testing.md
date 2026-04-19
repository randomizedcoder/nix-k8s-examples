# Resilience Testing

This project ships with a chaos / failover verification tool — `k8s-chaos-failover` —
that stress-tests the cluster's HA behaviour by killing MicroVMs one at a time
while a continuous transactional workload runs against every database. It is
the repository's primary means of building confidence that the cluster, the CNI,
and each stateful workload actually survive node loss the way their HA stories
claim they do.

## What the tool does

For each of the four MicroVMs (`cp0`, `cp1`, `cp2`, `w3`) on each round it:

1. Waits for a pre-kill health gate (`kubectl get --raw /readyz` returns `ok`
   and the target node reports `Ready=True`).
2. Records the current CNPG primary (for attribution later).
3. SIGTERMs the QEMU process, SIGKILLs after a 2-second grace period. This is
   a **sudden power-off**, not a graceful drain — the point is to simulate real
   node failure.
4. Immediately rebuilds and restarts the VM.
5. Polls `kubectl get node` until the kubelet rejoins.
6. For each DB, scans its workload log for the first `OK` transaction strictly
   after the kill timestamp and records the delta as `recover_sec`.
7. Waits `--post-round-wait` seconds (default 120s) before the next kill so
   raft-based components (etcd, PD, FDB coordinators, ClickHouse Keeper) can
   re-converge.

Meanwhile four background workload loops drive ~2 transactions/sec per DB:

| DB | Endpoint | Query |
|---|---|---|
| PostgreSQL (CNPG) | `$CP0_IP:30500` (`pg-rw-nodeport`) | `INSERT INTO chaos DEFAULT VALUES; SELECT count(*)` |
| TiDB | `$CP0_IP:30400` | `INSERT INTO chaos.t VALUES(NOW(6)); SELECT COUNT(*)` |
| ClickHouse | `$CP0_IP:30900` | `INSERT INTO chaos.t VALUES(now64()); SELECT count()` |
| FoundationDB | `kubectl exec` into a Ready fdb pod | `fdbcli --exec 'writemode on; set chaos:<ts> 1; get chaos:<ts>'` |

Each call is wrapped in `timeout 8-10` so a dead primary can't stall the loop.

Output lives in `./chaos-logs/`:

- `<db>.log` — nanosecond-timestamped `OK` / `FAIL <err>` lines, one per attempt.
- `summary.tsv` — `round | node | db | pg_primary_pre | recover_sec | rejoin_sec`.
- `events.log` — human-readable event stream.

## Reference run: 30 rounds × 4 nodes (2026-04-18)

A ~4.5-hour run was executed against a freshly rebuilt cluster, with PG and FDB
skipped (see [Known incompatibilities](#known-incompatibilities) below).

```
nix run .#k8s-chaos-failover -- \
  --rounds=30 --interval=60 --post-round-wait=120 --warmup=30 \
  --skip-dbs=pg,fdb --log-dir=./chaos-logs-long
```

### Headline numbers

| | Value |
|---|---|
| Wall time | 4 h 34 min |
| SIGKILL events | 120 (30 rounds × 4 nodes) |
| TiDB workload | 24,398 OK / 2,602 FAIL — **90.36% transaction success** |
| ClickHouse workload | 19,086 OK / 1,947 FAIL — **90.74% transaction success** |

### Recovery distribution

| DB | Measured kills | Min | Mean | Max |
|---|---|---|---|---|
| ClickHouse | 83 / 120 | 0.002 s | 2.74 s | 42.66 s |
| TiDB | 58 / 120 | 0.004 s | 4.86 s | 42.59 s |

(Of the 120 kills, some measurements recorded `-1` because the tool's single-shot
recovery read happened a few ms before the workload's next completed poll. This
is a known measurement-window limitation — not a DB outage. The workload `.log`
files still show OK entries for the majority of these; a future refinement
should poll the log for up to N seconds rather than read once.)

### Leader re-elections observed

| Component | Leader changes |
|---|---|
| etcd (k8s control plane) | ≥6 total (per-member counters: cp0=3, cp1=2, cp2=1 since last restart) |
| TiDB PD (raft) | 2 over all 120 kills — 118 / 120 kills did not dislodge the PD leader |
| CNPG PG primary | 3 promotions before PG was put on the skip list |
| ClickHouse Keeper | ~10–15 raft leader changes across the 3 keepers |
| Kubelet node transitions (`NodeNotReady` + `NodeReady` events) | 182 |

TiDB PD's **98.3% leader retention** under continuous single-node loss is the
clearest win — it is exactly what a well-tuned raft ensemble should look like.

## Known incompatibilities

### PostgreSQL (CNPG) + node-local storage

In this cluster CNPG is backed by `rancher/local-path-provisioner` (node-local
PVs, no replication at the storage layer). A sudden QEMU power-off kills the
pod hard — PostgreSQL's `pg_control` file is not guaranteed to be fsync'd at
that instant. When the node comes back, `pg_controldata` reads a truncated
control file and the pod enters `CrashLoopBackOff`. Repeated across every CP
this corrupts every replica.

**This is a fundamental storage-layer mismatch, not a CNPG bug.** To run PG
through chaos in this repo, one of the following is needed:

- Replace local-path with a replicated CSI (Longhorn, Rook-Ceph).
- Redefine chaos as a graceful ACPI shutdown (QMP `system_powerdown`) — no
  longer a true chaos test, but tests drain behaviour.
- Enable CNPG's `synchronous_commit=remote_apply` with 3 synchronous replicas
  so a committed transaction exists on ≥2 nodes before ack — but this still
  leaves the dead node's `pg_control` corrupt; CNPG would need to
  re-bootstrap it via `pg_rewind`.

For now, use `--skip-dbs=pg` in chaos runs.

### FoundationDB bootstrap

FDB's `fdb-init` Job sometimes fails to establish the database after a cluster
rebuild (the `configure new triple ssd` command hangs). Once the cluster is
initialised correctly it is expected to survive single-node kills (3 coordinators
on cp0/cp1/cp2, quorum of 2). This is an initialisation reliability issue, not
a resilience one — investigation is tracked separately.

## Operator's recipe

Quick smoke (< 5 min):

```bash
nix run .#k8s-chaos-failover -- --rounds=1 --interval=30 --warmup=10
```

Reference run (what we did above; ~4.5 hours):

```bash
nix run .#k8s-chaos-failover -- \
  --rounds=30 --interval=60 --post-round-wait=120 --warmup=30 \
  --skip-dbs=pg,fdb
```

Target a single node:

```bash
nix run .#k8s-chaos-failover -- --nodes=w3 --rounds=5
```

Watch progress live while the run proceeds:

```bash
tail -f ./chaos-logs/events.log
# or per-DB:
tail -f ./chaos-logs/tidb.log
```

Inspect which round/kill had the worst recovery:

```bash
sort -t$'\t' -k5 -g ./chaos-logs/summary.tsv | tail -10
```

## Extending the tool

Because the cluster is a platform, not a single app, it's expected that new
stateful components will be added over time. Each one is a candidate for chaos
coverage. To wire a new DB in:

1. **Add a NodePort** to the service manifest in `nix/gitops/env/<db>.nix` and
   pin its port in `nix/constants.nix`.
2. **Add an `ensure_<db>` and `run_workload_<db>` function** in
   `nix/chaos-scripts.nix`. Keep the transaction minimal (one INSERT + one
   SELECT) — the goal is recovery signal, not throughput.
3. **Register the DB name** in the `DBS=(...)` loop and the `skip_db` switch.
4. **Pick a reachable endpoint** — either a NodePort on `$CP0_IP`, or
   `kubectl exec` into a pod (FDB's pattern). Wrap every client call in
   `timeout 8-10` so a dead primary cannot stall the loop.
5. **Add the client binary** to `nix/shell.nix` and to the chaos script's
   `runtimeInputs`.

Future extensions under consideration:

- Network partitions (iptables/nft drop rules instead of VM kill).
- Multi-node simultaneous failures (2-of-3 CP loss to test etcd unavailability
  behaviour).
- Pod-level chaos (`kubectl delete pod --grace-period=0`) without taking the
  node down — exercises controller reconciliation instead of node-loss paths.
- Disk-pressure / fsync-latency injection (e.g. via `ionice` + `cgroup`
  throttling on the VM's data image).
- A continuous-history mode that appends each run's summary to a single
  TSV so trends across upgrades become visible.

The chaos tool is intentionally plain shell so any of these can be added
without plumbing a new test framework in.

## Why this matters

Every HA story in this repo — kube-apiserver behind haproxy, etcd raft, Cilium
replacing kube-proxy, CNPG streaming replication, TiDB PD/TiKV raft, ClickHouse
ReplicatedMergeTree, FDB coordinators — makes a claim about what happens when
a node dies. Without a mechanical way to test those claims, upgrades quietly
regress and misconfigurations go unnoticed until production. `k8s-chaos-failover`
is how this repo catches those regressions early.
