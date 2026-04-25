# nix/gitops/env/clickhouse.nix
#
# ClickHouse — 4-node K8s deployment: 2 shards × 2 replicas + 3 Keeper.
#
#   Quorum layer: 3 clickhouse-keeper pods (odd quorum for Raft).
#   Data layer:   4 clickhouse-server pods, laid out as
#                 ordinal 0 → shard 1 replica 1 (cp0)
#                 ordinal 1 → shard 1 replica 2 (cp1)
#                 ordinal 2 → shard 2 replica 1 (cp2)
#                 ordinal 3 → shard 2 replica 2 (w3)
#
# Tables created with ReplicatedMergeTree('/clickhouse/tables/{shard}/{table}',
# '{replica}') auto-replicate between the two pods of each shard via Keeper.
#
# Shard/replica macros are computed per-pod in an init container from the
# StatefulSet pod ordinal.
#
{ pkgs, lib }:
let
  constants = import ../../constants.nix;
  ns = "clickhouse";
  domain = "svc.cluster.local";
  version = "24.3";

  keeperHosts = builtins.map
    (i: "clickhouse-keeper-${toString i}.ck-keeper-headless.${ns}.${domain}")
    [ 0 1 2 ];

  serverHosts = builtins.map
    (i: "clickhouse-${toString i}.clickhouse-headless.${ns}.${domain}")
    [ 0 1 2 3 ];
in
{
  manifests = [
    # ─── Keeper ConfigMap ──────────────────────────────────────────────
    # server_id is computed per-pod in the init container from the ordinal.
    {
      name = "clickhouse/configmap-keeper.yaml";
      content = ''
        apiVersion: v1
        kind: ConfigMap
        metadata:
          name: ck-keeper-config
          namespace: ${ns}
        data:
          keeper_config.xml: |
            <clickhouse>
              <logger>
                <level>information</level>
                <console>1</console>
              </logger>
              <listen_host>0.0.0.0</listen_host>
              <keeper_server>
                <tcp_port>9181</tcp_port>
                <server_id from_env="KEEPER_SERVER_ID"/>
                <log_storage_path>/var/lib/clickhouse-keeper/log</log_storage_path>
                <snapshot_storage_path>/var/lib/clickhouse-keeper/snapshots</snapshot_storage_path>
                <coordination_settings>
                  <operation_timeout_ms>10000</operation_timeout_ms>
                  <session_timeout_ms>30000</session_timeout_ms>
                  <raft_logs_level>information</raft_logs_level>
                </coordination_settings>
                <raft_configuration>
                  <server>
                    <id>1</id>
                    <hostname>${builtins.elemAt keeperHosts 0}</hostname>
                    <port>9234</port>
                  </server>
                  <server>
                    <id>2</id>
                    <hostname>${builtins.elemAt keeperHosts 1}</hostname>
                    <port>9234</port>
                  </server>
                  <server>
                    <id>3</id>
                    <hostname>${builtins.elemAt keeperHosts 2}</hostname>
                    <port>9234</port>
                  </server>
                </raft_configuration>
              </keeper_server>
            </clickhouse>
      '';
    }

    # ─── Keeper Headless Service ───────────────────────────────────────
    {
      name = "clickhouse/service-keeper-headless.yaml";
      content = ''
        apiVersion: v1
        kind: Service
        metadata:
          name: ck-keeper-headless
          namespace: ${ns}
        spec:
          clusterIP: None
          publishNotReadyAddresses: true
          selector:
            app: clickhouse-keeper
          ports:
          - name: client
            port: 9181
            targetPort: 9181
          - name: raft
            port: 9234
            targetPort: 9234
      '';
    }

    # ─── Keeper StatefulSet ────────────────────────────────────────────
    {
      name = "clickhouse/statefulset-keeper.yaml";
      content = ''
        apiVersion: apps/v1
        kind: StatefulSet
        metadata:
          name: clickhouse-keeper
          namespace: ${ns}
        spec:
          serviceName: ck-keeper-headless
          replicas: 3
          selector:
            matchLabels:
              app: clickhouse-keeper
          template:
            metadata:
              labels:
                app: clickhouse-keeper
            spec:
              affinity:
                podAntiAffinity:
                  requiredDuringSchedulingIgnoredDuringExecution:
                  - labelSelector:
                      matchLabels:
                        app: clickhouse-keeper
                    topologyKey: kubernetes.io/hostname
              securityContext:
                runAsUser: 0
              containers:
              - name: keeper
                image: clickhouse/clickhouse-keeper:${version}
                # server_id = ordinal + 1 (matches raft_configuration ids 1..3)
                command: ["/bin/sh", "-c"]
                args:
                - |
                  ordinal=''${HOSTNAME##*-}
                  export KEEPER_SERVER_ID=$((ordinal + 1))
                  exec /usr/bin/clickhouse-keeper --config=/etc/clickhouse-keeper/keeper_config.xml
                env:
                - name: HOSTNAME
                  valueFrom:
                    fieldRef:
                      fieldPath: metadata.name
                ports:
                - containerPort: 9181
                  name: client
                - containerPort: 9234
                  name: raft
                volumeMounts:
                - name: config
                  mountPath: /etc/clickhouse-keeper/keeper_config.xml
                  subPath: keeper_config.xml
                - name: data
                  mountPath: /var/lib/clickhouse-keeper
                resources:
                  requests:
                    cpu: 100m
                    memory: 256Mi
                  limits:
                    cpu: 500m
                    memory: 512Mi
              volumes:
              - name: config
                configMap:
                  name: ck-keeper-config
              - name: data
                emptyDir: {}
      '';
    }

    # ─── Server ConfigMap ──────────────────────────────────────────────
    # macros (shard/replica) are written per-pod by the init container.
    {
      name = "clickhouse/configmap-server.yaml";
      content = ''
        apiVersion: v1
        kind: ConfigMap
        metadata:
          name: clickhouse-config
          namespace: ${ns}
        data:
          cluster.xml: |
            <clickhouse>
              <listen_host>0.0.0.0</listen_host>
              <http_port>8123</http_port>
              <tcp_port>9000</tcp_port>
              <interserver_http_port>9009</interserver_http_port>
              <interserver_http_host from_env="POD_FQDN"/>
              <remote_servers>
                <ch4>
                  <shard>
                    <internal_replication>true</internal_replication>
                    <replica>
                      <host>${builtins.elemAt serverHosts 0}</host>
                      <port>9000</port>
                    </replica>
                    <replica>
                      <host>${builtins.elemAt serverHosts 1}</host>
                      <port>9000</port>
                    </replica>
                  </shard>
                  <shard>
                    <internal_replication>true</internal_replication>
                    <replica>
                      <host>${builtins.elemAt serverHosts 2}</host>
                      <port>9000</port>
                    </replica>
                    <replica>
                      <host>${builtins.elemAt serverHosts 3}</host>
                      <port>9000</port>
                    </replica>
                  </shard>
                </ch4>
              </remote_servers>
              <zookeeper>
                <node>
                  <host>${builtins.elemAt keeperHosts 0}</host>
                  <port>9181</port>
                </node>
                <node>
                  <host>${builtins.elemAt keeperHosts 1}</host>
                  <port>9181</port>
                </node>
                <node>
                  <host>${builtins.elemAt keeperHosts 2}</host>
                  <port>9181</port>
                </node>
              </zookeeper>
              <distributed_ddl>
                <path>/clickhouse/task_queue/ddl</path>
              </distributed_ddl>
            </clickhouse>
          init-macros.sh: |
            #!/bin/sh
            set -e
            ordinal=''${HOSTNAME##*-}
            shard=$((ordinal / 2 + 1))
            replica=$((ordinal % 2 + 1))
            cat > /macros-out/macros.xml <<EOF
            <clickhouse>
              <macros>
                <cluster>ch4</cluster>
                <shard>$shard</shard>
                <replica>$replica</replica>
              </macros>
            </clickhouse>
            EOF
            echo "ordinal=$ordinal shard=$shard replica=$replica"
      '';
    }

    # ─── Server Headless Service ───────────────────────────────────────
    {
      name = "clickhouse/service-headless.yaml";
      content = ''
        apiVersion: v1
        kind: Service
        metadata:
          name: clickhouse-headless
          namespace: ${ns}
        spec:
          clusterIP: None
          publishNotReadyAddresses: true
          selector:
            app: clickhouse
          ports:
          - name: http
            port: 8123
            targetPort: 8123
          - name: native
            port: 9000
            targetPort: 9000
          - name: interserver
            port: 9009
            targetPort: 9009
      '';
    }

    # ─── Server Client Service ─────────────────────────────────────────
    {
      name = "clickhouse/service.yaml";
      content = ''
        apiVersion: v1
        kind: Service
        metadata:
          name: clickhouse
          namespace: ${ns}
        spec:
          selector:
            app: clickhouse
          ports:
          - name: http
            port: 8123
            targetPort: 8123
            nodePort: ${toString constants.clickhouse.nodePortHttp}
          - name: native
            port: 9000
            targetPort: 9000
            nodePort: ${toString constants.clickhouse.nodePortNative}
          type: NodePort
      '';
    }

    # ─── Local-affinity Service (collector → node-local CH replica) ────
    # ClusterIP Service with internalTrafficPolicy: Local — kube-proxy /
    # cilium will only route to a CH pod on the same node as the caller,
    # avoiding cross-node hops for high-volume telemetry writes. The
    # otel-collector DaemonSet is co-located with CH (every cp/worker
    # node carries one CH replica + one collector pod), so a local pod
    # is always available. Used by the collector's clickhouse exporter;
    # the regular `clickhouse` Service stays cluster-wide for clients
    # like HyperDX/clickstack-app and ad-hoc queries.
    {
      name = "clickhouse/service-local.yaml";
      content = ''
        apiVersion: v1
        kind: Service
        metadata:
          name: clickhouse-local
          namespace: ${ns}
        spec:
          selector:
            app: clickhouse
          internalTrafficPolicy: Local
          ports:
          - name: http
            port: 8123
            targetPort: 8123
          - name: native
            port: 9000
            targetPort: 9000
          type: ClusterIP
      '';
    }

    # ─── Server StatefulSet ────────────────────────────────────────────
    {
      name = "clickhouse/statefulset.yaml";
      content = ''
        apiVersion: apps/v1
        kind: StatefulSet
        metadata:
          name: clickhouse
          namespace: ${ns}
        spec:
          serviceName: clickhouse-headless
          replicas: 4
          selector:
            matchLabels:
              app: clickhouse
          template:
            metadata:
              labels:
                app: clickhouse
            spec:
              affinity:
                podAntiAffinity:
                  requiredDuringSchedulingIgnoredDuringExecution:
                  - labelSelector:
                      matchLabels:
                        app: clickhouse
                    topologyKey: kubernetes.io/hostname
              initContainers:
              - name: macros
                image: clickhouse/clickhouse-server:${version}
                command: ["/bin/sh", "/scripts/init-macros.sh"]
                env:
                - name: HOSTNAME
                  valueFrom:
                    fieldRef:
                      fieldPath: metadata.name
                volumeMounts:
                - name: scripts
                  mountPath: /scripts
                - name: macros-out
                  mountPath: /macros-out
              securityContext:
                runAsUser: 0
              containers:
              - name: clickhouse
                image: clickhouse/clickhouse-server:${version}
                # Wrap launch to compute POD_FQDN for interserver_http_host:
                # downward API can't give us fully-qualified DNS, but replicas
                # must advertise a name peers can reach.
                command: ["/bin/sh", "-c"]
                args:
                - |
                  export POD_FQDN="$(hostname).clickhouse-headless.${ns}.${domain}"
                  exec /usr/bin/clickhouse-server --config-file=/etc/clickhouse-server/config.xml
                ports:
                - containerPort: 8123
                  name: http
                - containerPort: 9000
                  name: native
                - containerPort: 9009
                  name: interserver
                volumeMounts:
                - name: config
                  mountPath: /etc/clickhouse-server/config.d/cluster.xml
                  subPath: cluster.xml
                - name: macros-out
                  mountPath: /etc/clickhouse-server/config.d/macros.xml
                  subPath: macros.xml
                - name: data
                  mountPath: /var/lib/clickhouse
                resources:
                  requests:
                    cpu: 200m
                    memory: 512Mi
                  limits:
                    cpu: '1'
                    memory: 2Gi
              volumes:
              - name: config
                configMap:
                  name: clickhouse-config
                  items:
                  - key: cluster.xml
                    path: cluster.xml
              - name: scripts
                configMap:
                  name: clickhouse-config
                  defaultMode: 0755
                  items:
                  - key: init-macros.sh
                    path: init-macros.sh
              - name: macros-out
                emptyDir: {}
              - name: data
                emptyDir: {}
      '';
    }
    {
      name = "clickhouse/application.yaml";
      content = ''
        apiVersion: argoproj.io/v1alpha1
        kind: Application
        metadata:
          name: clickhouse
          namespace: argocd
        spec:
          project: default
          source:
            repoURL: ${constants.gitops.repoURL}
            targetRevision: ${constants.gitops.targetRevision}
            path: ${constants.gitops.renderedPath}/clickhouse
            directory:
              exclude: 'application.yaml'
          destination:
            server: https://kubernetes.default.svc
            namespace: ${ns}
          syncPolicy:
            automated:
              prune: true
              selfHeal: true
      '';
    }
  ];
}
