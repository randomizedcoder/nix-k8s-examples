# nix/gitops/matrix/maubot.nix
#
# maubot — Python bot framework with a web UI for installing plugins.
#
# Data layout:
#   - Maubot's plugin state + user sessions live in the CNPG `maubot`
#     database (HA for free).
#   - The management web UI is exposed via Ingress at ${maubotHost}.
#     Admin password lives in matrix-secrets (key: `maubot-admin-pass`).
#
# Appservice registration: maubot registers plugin-as-bot users in the
# Matrix user namespace `@_maubot_.*`. Tokens are placeholders in this
# ConfigMap — operator replaces them at install time.
#
{ constants }:
let
  m   = constants.matrix;
  mns = "matrix";
in
{
  manifests = [
    {
      name = "matrix/maubot-registration.yaml";
      content = ''
        apiVersion: v1
        kind: ConfigMap
        metadata:
          name: maubot-registration
          namespace: ${mns}
          annotations:
            argocd.argoproj.io/sync-wave: "3"
            argocd.argoproj.io/compare-options: IgnoreExtraneous
        data:
          registration.yaml: |
            id: maubot
            url: http://maubot.matrix.svc.cluster.local:29316
            as_token: REPLACE_ME_MAUBOT_AS_TOKEN
            hs_token: REPLACE_ME_MAUBOT_HS_TOKEN
            sender_localpart: maubot
            rate_limited: false
            namespaces:
              users:
              - exclusive: true
                regex: "@_maubot_.*"
              aliases: []
              rooms: []
            de.sorunome.msc2409.push_ephemeral: true
            push_ephemeral: true
      '';
    }

    {
      name = "matrix/maubot-config.yaml";
      content = ''
        apiVersion: v1
        kind: ConfigMap
        metadata:
          name: maubot-config
          namespace: ${mns}
          annotations:
            argocd.argoproj.io/sync-wave: "3"
            argocd.argoproj.io/compare-options: IgnoreExtraneous
        data:
          config.yaml: |
            database: postgresql://app@pg-rw.postgres.svc.cluster.local/maubot
            crypto_database: default
            plugin_directories:
              upload: ./plugins
              load:
              - ./plugins
              trash: delete
              db: ./plugins/dbs
            plugin_databases:
              postgres: postgresql://app@pg-rw.postgres.svc.cluster.local/maubot
              postgres_max_conns_per_plugin: 3
              sqlite: ./plugins/dbs
            server:
              hostname: 0.0.0.0
              port: 29316
              public_url: https://${m.maubotHost}
              unshared_secret: REPLACE_ME_MAUBOT_UNSHARED_SECRET
            admins:
              admin: REPLACE_ME_MAUBOT_ADMIN_BCRYPT
            homeservers:
              ${m.serverName}:
                url: http://synapse.matrix.svc.cluster.local:8008
                secret: REPLACE_ME_MAUBOT_AS_TOKEN
            logging:
              version: 1
              formatters:
                colored:
                  (): maubot.lib.color_log.ColorFormatter
                  format: "[%(asctime)s] [%(levelname)s@%(name)s] %(message)s"
              handlers:
                console:
                  class: logging.StreamHandler
                  formatter: colored
              loggers:
                maubot:   { level: DEBUG }
                mau:      { level: DEBUG }
                aiohttp:  { level: INFO }
              root:
                level: DEBUG
                handlers: [console]
      '';
    }

    {
      name = "matrix/maubot-pvc.yaml";
      content = ''
        apiVersion: v1
        kind: PersistentVolumeClaim
        metadata:
          name: maubot-plugins
          namespace: ${mns}
          annotations:
            argocd.argoproj.io/sync-wave: "3"
        spec:
          accessModes: [ReadWriteOnce]
          storageClassName: local-path
          resources:
            requests: { storage: 1Gi }
      '';
    }

    {
      name = "matrix/maubot-deployment.yaml";
      content = ''
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: maubot
          namespace: ${mns}
          annotations:
            argocd.argoproj.io/sync-wave: "6"
        spec:
          replicas: 1
          strategy: { type: Recreate }
          selector:
            matchLabels: { app: maubot }
          template:
            metadata:
              labels: { app: maubot }
            spec:
              nodeSelector:
                kubernetes.io/hostname: k8s-w3
              tolerations:
              - key: node-role.kubernetes.io/control-plane
                operator: Exists
                effect: NoSchedule
              containers:
              - name: maubot
                image: ${m.images.maubot}
                ports:
                - { name: http, containerPort: 29316 }
                readinessProbe:
                  httpGet: { path: /_matrix/maubot/v1/version, port: 29316 }
                  initialDelaySeconds: 10
                  periodSeconds: 10
                resources:
                  requests: { cpu: 50m,  memory: 128Mi }
                  limits:   { cpu: 500m, memory: 512Mi }
                env:
                - name: UID
                  value: "1337"
                - name: GID
                  value: "1337"
                volumeMounts:
                - { name: data,   mountPath: /data }
                - { name: config, mountPath: /data/config.yaml, subPath: config.yaml, readOnly: true }
              volumes:
              - name: data
                persistentVolumeClaim: { claimName: maubot-plugins }
              - name: config
                configMap:
                  name: maubot-config
                  items: [{ key: config.yaml, path: config.yaml }]
      '';
    }

    {
      name = "matrix/maubot-service.yaml";
      content = ''
        apiVersion: v1
        kind: Service
        metadata:
          name: maubot
          namespace: ${mns}
          annotations:
            argocd.argoproj.io/sync-wave: "6"
        spec:
          type: ClusterIP
          selector: { app: maubot }
          ports:
          - { name: http, port: 29316, targetPort: 29316 }
      '';
    }
  ];
}
