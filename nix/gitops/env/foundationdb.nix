# nix/gitops/env/foundationdb.nix
#
# FoundationDB — HA KV store deployed as a replacement for TiDB.
#
# Layout (plain-string-YAML style, no operator):
#   1 StatefulSet `fdb` x3 replicas — each pod runs a single `fdbserver`
#     process acting as coordinator + storage + log + stateless. Pod
#     anti-affinity spreads the 3 pods across the 4-node cluster.
#   Redundancy mode `triple ssd` → 3-way replication across the 3 pods.
#
# Bootstrap: `fdb-init` Job runs `configure new triple ssd` once
# (idempotent; no-op after initial config).
#
# Benchmark: `fdb-bench` Job drives load via `fdbcli` + bash inside the
# foundationdb/foundationdb image — pods have no pypi egress so we can't
# use the Python bindings, and the image (CentOS 7, Python 2, no mako)
# doesn't ship a workload generator. Bash + fdbcli is native and
# self-contained.
#
{ pkgs, lib }:
let
  version = "7.3.27";
  ns = "fdb";
  domain = "svc.cluster.local";

  fdbHosts = builtins.map
    (i: "fdb-${toString i}.fdb-headless.${ns}.${domain}")
    [ 0 1 2 ];
  coordinators = lib.concatStringsSep ","
    (builtins.map (h: "${h}:4500") fdbHosts);

  clusterFile = "k8s:k8s@${coordinators}";
in
{
  manifests = [
    # ─── FDB ConfigMap (cluster file + start script) ───────────────────
    {
      name = "fdb/configmap-fdb.yaml";
      content = builtins.concatStringsSep "\n" [
        "apiVersion: v1"
        "kind: ConfigMap"
        "metadata:"
        "  name: fdb-config"
        "  namespace: ${ns}"
        "data:"
        "  fdb.cluster: |"
        "    ${clusterFile}"
        "  start-fdb.sh: |"
        "    #!/bin/sh"
        "    set -e"
        "    mkdir -p /var/fdb /data /var/log/fdb"
        "    # Cluster file must be writable — fdbserver rewrites it when"
        "    # coordinators change. Copy from RO configmap to writable path."
        "    cp /etc/fdb-config/fdb.cluster /var/fdb/fdb.cluster"
        "    chmod 644 /var/fdb/fdb.cluster"
        "    exec fdbserver \\"
        "      --public-address \$POD_IP:4500 \\"
        "      --listen-address 0.0.0.0:4500 \\"
        "      --datadir /data \\"
        "      --logdir /var/log/fdb \\"
        "      --cluster-file /var/fdb/fdb.cluster"
      ];
    }

    # ─── FDB Headless Service ──────────────────────────────────────────
    {
      name = "fdb/service-fdb-headless.yaml";
      content = builtins.concatStringsSep "\n" [
        "apiVersion: v1"
        "kind: Service"
        "metadata:"
        "  name: fdb-headless"
        "  namespace: ${ns}"
        "spec:"
        "  clusterIP: None"
        "  publishNotReadyAddresses: true"
        "  selector:"
        "    app: fdb"
        "  ports:"
        "  - name: fdb"
        "    port: 4500"
        "    targetPort: 4500"
      ];
    }

    # ─── FDB StatefulSet ───────────────────────────────────────────────
    {
      name = "fdb/statefulset-fdb.yaml";
      content = builtins.concatStringsSep "\n" [
        "apiVersion: apps/v1"
        "kind: StatefulSet"
        "metadata:"
        "  name: fdb"
        "  namespace: ${ns}"
        "spec:"
        "  serviceName: fdb-headless"
        "  # 4 fdbserver processes across cp0/cp1/cp2/w3. Only fdb-0..2 are"
        "  # coordinators (see fdb.cluster in configmap); fdb-3 joins as a"
        "  # storage/log peer. Triple-ssd replication + 1 spare node →"
        "  # survives a single-node failure with zero data-path impact."
        "  replicas: 4"
        "  selector:"
        "    matchLabels:"
        "      app: fdb"
        "  template:"
        "    metadata:"
        "      labels:"
        "        app: fdb"
        "    spec:"
        "      affinity:"
        "        podAntiAffinity:"
        "          requiredDuringSchedulingIgnoredDuringExecution:"
        "          - labelSelector:"
        "              matchLabels:"
        "                app: fdb"
        "            topologyKey: kubernetes.io/hostname"
        "      containers:"
        "      - name: fdb"
        "        image: foundationdb/foundationdb:${version}"
        "        command: [\"/bin/sh\", \"/config/start-fdb.sh\"]"
        "        env:"
        "        - name: POD_IP"
        "          valueFrom:"
        "            fieldRef:"
        "              fieldPath: status.podIP"
        "        ports:"
        "        - containerPort: 4500"
        "          name: fdb"
        "        volumeMounts:"
        "        - name: config"
        "          mountPath: /config"
        "        - name: fdb-config"
        "          mountPath: /etc/fdb-config"
        "        - name: data"
        "          mountPath: /data"
        "        resources:"
        "          requests:"
        "            cpu: 500m"
        "            memory: 1Gi"
        "          limits:"
        "            cpu: '1'"
        "            memory: 2Gi"
        "      volumes:"
        "      - name: config"
        "        configMap:"
        "          name: fdb-config"
        "          defaultMode: 0755"
        "          items:"
        "          - key: start-fdb.sh"
        "            path: start-fdb.sh"
        "      - name: fdb-config"
        "        configMap:"
        "          name: fdb-config"
        "          items:"
        "          - key: fdb.cluster"
        "            path: fdb.cluster"
        "      - name: data"
        "        emptyDir: {}"
      ];
    }

    # ─── FDB Bootstrap Job ─────────────────────────────────────────────
    {
      name = "fdb/job-fdb-init.yaml";
      content = builtins.concatStringsSep "\n" [
        "apiVersion: batch/v1"
        "kind: Job"
        "metadata:"
        "  name: fdb-init"
        "  namespace: ${ns}"
        "spec:"
        "  backoffLimit: 5"
        "  template:"
        "    metadata:"
        "      labels:"
        "        app: fdb-init"
        "    spec:"
        "      restartPolicy: OnFailure"
        "      containers:"
        "      - name: init"
        "        image: foundationdb/foundationdb:${version}"
        "        command: [\"/bin/sh\", \"-c\"]"
        "        args:"
        "        - |"
        "          set -e"
        "          mkdir -p /var/fdb"
        "          cp /etc/fdb-config/fdb.cluster /var/fdb/fdb.cluster"
        "          echo '=== Waiting for FDB coordinators ==='"
        "          for host in ${lib.concatStringsSep " " fdbHosts}; do"
        "            until nc -z -w2 \$host 4500 2>/dev/null; do"
        "              echo \"  waiting for \$host:4500\""
        "              sleep 2"
        "            done"
        "            echo \"  \$host:4500 reachable\""
        "          done"
        "          echo ''"
        "          echo '=== Configuring database (triple ssd) ==='"
        "          fdbcli -C /var/fdb/fdb.cluster --timeout 60 --exec 'configure new triple ssd' || true"
        "          sleep 3"
        "          echo ''"
        "          echo '=== FDB status ==='"
        "          fdbcli -C /var/fdb/fdb.cluster --timeout 60 --exec 'status'"
        "        volumeMounts:"
        "        - name: fdb-config"
        "          mountPath: /etc/fdb-config"
        "      volumes:"
        "      - name: fdb-config"
        "        configMap:"
        "          name: fdb-config"
        "          items:"
        "          - key: fdb.cluster"
        "            path: fdb.cluster"
      ];
    }

    # ─── Benchmark ConfigMap (bench.sh) ────────────────────────────────
    # Bash + fdbcli benchmark. Workload mirrors sysbench oltp_read_write:
    # 4 workers, 60s, 40K-key dataset, 13 ops/txn (10 get + 2 set + 1 ins).
    {
      name = "fdb/configmap-bench.yaml";
      content = builtins.concatStringsSep "\n" [
        "apiVersion: v1"
        "kind: ConfigMap"
        "metadata:"
        "  name: fdb-bench"
        "  namespace: ${ns}"
        "data:"
        "  bench.sh: |"
        "    #!/bin/bash"
        "    set -eu"
        "    CLUSTER=/var/fdb/fdb.cluster"
        "    ROWS=40000"
        "    WORKERS=4"
        "    DURATION=60"
        "    TXNS_PER_BATCH=50"
        "    OPS_PER_TXN=13"
        ""
        "    echo \"=== Loading $ROWS keys ===\""
        "    T0=$(date +%s)"
        "    BATCH=500"
        "    for start in $(seq 0 $BATCH $((ROWS - 1))); do"
        "      (echo 'writemode on'; echo 'begin';"
        "       end=$((start + BATCH))"
        "       [ $end -gt $ROWS ] && end=$ROWS"
        "       for i in $(seq $start $((end - 1))); do"
        "         printf 'set k%08d v_loaded_%08d_xxxxxxxxxxxxxxxxxxxx\\n' $i $i"
        "       done"
        "       echo 'commit') | fdbcli -C $CLUSTER > /dev/null"
        "    done"
        "    T1=$(date +%s)"
        "    echo \"  loaded in $((T1 - T0))s\""
        "    echo ''"
        ""
        "    echo \"=== Running: $WORKERS workers, $DURATION s, mix=g10u2i1 ===\""
        "    TMPDIR=$(mktemp -d)"
        "    RUN_START=$(date +%s)"
        "    DEADLINE=$((RUN_START + DURATION))"
        ""
        "    gen_batch() {"
        "      local worker=$1 pass=$2"
        "      echo 'writemode on'"
        "      for t in $(seq 1 $TXNS_PER_BATCH); do"
        "        echo 'begin'"
        "        for _ in 1 2 3 4 5 6 7 8 9 10; do"
        "          printf 'get k%08d\\n' $((RANDOM * ROWS / 32768))"
        "        done"
        "        for _ in 1 2; do"
        "          printf 'set k%08d updated_%d_%d_%d_xxxxxxxx\\n' $((RANDOM * ROWS / 32768)) $worker $pass $t"
        "        done"
        "        printf 'set ins_w%d_p%d_t%d val_xxxxxxxxxxxxxxxxxxxxxxxxxx\\n' $worker $pass $t"
        "        echo 'commit'"
        "      done"
        "    }"
        ""
        "    for w in $(seq 1 $WORKERS); do"
        "      ("
        "        txns=0"
        "        pass=0"
        "        while [ $(date +%s) -lt $DEADLINE ]; do"
        "          gen_batch $w $pass | fdbcli -C $CLUSTER > /dev/null 2>&1"
        "          txns=$((txns + TXNS_PER_BATCH))"
        "          pass=$((pass + 1))"
        "        done"
        "        echo $txns > $TMPDIR/w$w"
        "      ) &"
        "    done"
        "    wait"
        "    RUN_END=$(date +%s)"
        "    ELAPSED=$((RUN_END - RUN_START))"
        ""
        "    TOTAL_TXNS=0"
        "    for w in $(seq 1 $WORKERS); do"
        "      T=$(cat $TMPDIR/w$w)"
        "      TOTAL_TXNS=$((TOTAL_TXNS + T))"
        "      echo \"  worker $w: $T txns\""
        "    done"
        "    TOTAL_OPS=$((TOTAL_TXNS * OPS_PER_TXN))"
        "    TPS=$(awk -v t=$TOTAL_TXNS -v e=$ELAPSED 'BEGIN{printf \"%.2f\", t/e}')"
        "    OPS=$(awk -v o=$TOTAL_OPS -v e=$ELAPSED 'BEGIN{printf \"%.2f\", o/e}')"
        "    AVG_LAT=$(awk -v t=$TOTAL_TXNS -v w=$WORKERS -v e=$ELAPSED 'BEGIN{if(t>0) printf \"%.2f\", (e*w*1000)/t; else print \"n/a\"}')"
        ""
        "    echo ''"
        "    echo '=== Results ==='"
        "    printf '  duration:      %d s\\n' $ELAPSED"
        "    printf '  transactions:  %d (%s/s)\\n' $TOTAL_TXNS $TPS"
        "    printf '  operations:    %d (%s/s)\\n' $TOTAL_OPS $OPS"
        "    printf '  avg latency:   %s ms (derived: elapsed*workers/txns)\\n' $AVG_LAT"
        "    echo ''"
        "    echo '=== FDB status after run ==='"
        "    fdbcli -C $CLUSTER --exec 'status'"
      ];
    }

    # ─── Benchmark Job ─────────────────────────────────────────────────
    {
      name = "fdb/job-bench.yaml";
      content = builtins.concatStringsSep "\n" [
        "apiVersion: batch/v1"
        "kind: Job"
        "metadata:"
        "  name: fdb-bench"
        "  namespace: ${ns}"
        "spec:"
        "  backoffLimit: 2"
        "  template:"
        "    metadata:"
        "      labels:"
        "        app: fdb-bench"
        "    spec:"
        "      restartPolicy: Never"
        "      initContainers:"
        "      - name: wait-for-fdb"
        "        image: foundationdb/foundationdb:${version}"
        "        command: [\"/bin/sh\", \"-c\"]"
        "        args:"
        "        - |"
        "          set -e"
        "          mkdir -p /var/fdb"
        "          cp /etc/fdb-config/fdb.cluster /var/fdb/fdb.cluster"
        "          for i in \$(seq 1 60); do"
        "            if fdbcli -C /var/fdb/fdb.cluster --timeout 5 --exec 'status minimal' 2>&1 | grep -q 'available'; then"
        "              echo 'FDB is available'"
        "              exit 0"
        "            fi"
        "            echo \"  waiting for FDB (\$i/60)\""
        "            sleep 5"
        "          done"
        "          echo 'Timeout waiting for FDB'"
        "          exit 1"
        "        volumeMounts:"
        "        - name: fdb-config"
        "          mountPath: /etc/fdb-config"
        "        - name: data"
        "          mountPath: /var/fdb"
        "      containers:"
        "      - name: bench"
        "        image: foundationdb/foundationdb:${version}"
        "        command: [\"/bin/bash\", \"/bench/bench.sh\"]"
        "        volumeMounts:"
        "        - name: fdb-config"
        "          mountPath: /etc/fdb-config"
        "        - name: data"
        "          mountPath: /var/fdb"
        "        - name: bench-script"
        "          mountPath: /bench"
        "        resources:"
        "          requests:"
        "            cpu: 500m"
        "            memory: 256Mi"
        "          limits:"
        "            cpu: '2'"
        "            memory: 1Gi"
        "      volumes:"
        "      - name: fdb-config"
        "        configMap:"
        "          name: fdb-config"
        "          items:"
        "          - key: fdb.cluster"
        "            path: fdb.cluster"
        "      - name: bench-script"
        "        configMap:"
        "          name: fdb-bench"
        "          defaultMode: 0755"
        "          items:"
        "          - key: bench.sh"
        "            path: bench.sh"
        "      - name: data"
        "        emptyDir: {}"
      ];
    }
  ];
}
