# nix/gitops/matrix/synapse.nix
#
# Synapse — the Matrix homeserver itself.
#
# Layout:
#   - ConfigMap `synapse-config` holds non-secret config: homeserver.yaml
#     (minus DB password + the three *_secret keys) and log.config.
#   - Secret `matrix-secrets` (operator-created; see docs/matrix.md)
#     holds `homeserver.secrets.yaml` containing macaroon_secret_key,
#     form_secret, registration_shared_secret, and the full
#     `database:` block (with the `password`). Also contains AS/HS
#     tokens used by the bridge ConfigMaps below, plus a bcrypted
#     maubot admin password.
#   - The Synapse container is started with `--config-path` applied
#     TWICE — once for the ConfigMap file, once for the Secret-sourced
#     overlay. Synapse merges multiple config paths at startup; later
#     wins. This keeps secrets out of the ConfigMap.
#   - PVC `synapse-media` (${toString m.mediaStorageGi}Gi, local-path,
#     pinned to w3) holds `signing.key`, `media_store/`, and the on-disk
#     keystore. An initContainer runs `--generate-keys` on first boot to
#     create the signing key if the PVC is empty.
#   - NodePort on `synapseAdminNodePort` lets the dev host reach the
#     admin API directly for ad-hoc `register_new_matrix_user`.
#
{ constants }:
let
  m   = constants.matrix;
  mns = "matrix";
in
{
  manifests = [
    {
      name = "matrix/synapse-configmap.yaml";
      content = ''
        apiVersion: v1
        kind: ConfigMap
        metadata:
          name: synapse-config
          namespace: ${mns}
          annotations:
            argocd.argoproj.io/sync-wave: "3"
        data:
          homeserver.yaml: |
            server_name: "${m.serverName}"
            public_baseurl: "https://${m.serverName}/"
            pid_file: /data/homeserver.pid
            web_client_location: https://${m.elementHost}/
            report_stats: false
            signing_key_path: /data/signing.key
            trusted_key_servers: []

            listeners:
            - port: 8008
              tls: false
              type: http
              x_forwarded: true
              bind_addresses: ['0.0.0.0']
              resources:
              - names: [client, federation]
                compress: false

            # NOTE: `database:` is OVERRIDDEN by the Secret-sourced
            # overlay (matrix-secrets → homeserver.secrets.yaml). The
            # stub here is a placeholder so `--generate-keys` can parse
            # the file; Synapse never uses these creds.
            database:
              name: psycopg2
              args:
                user: app
                database: synapse
                host: pg-rw.postgres.svc.cluster.local
                port: 5432
                cp_min: 5
                cp_max: 10

            log_config: /etc/synapse/log.config

            media_store_path: /data/media_store
            max_upload_size: 50M
            uploads_path: /data/uploads
            enable_media_repo: true

            enable_registration: false
            registration_requires_token: false
            allow_public_rooms_over_federation: false

            federation_domain_whitelist: []
            send_federation: ${if m.federation then "true" else "false"}

            app_service_config_files:
            - /etc/synapse/appservices/hookshot.yaml
            - /etc/synapse/appservices/maubot.yaml
            - /etc/synapse/appservices/mautrix-discord.yaml

            url_preview_enabled: false
            suppress_key_server_warning_on_no_federation: true
            serve_server_wellknown: true
            admin_contact: 'mailto:admin@${m.serverName}'
          log.config: |
            version: 1
            formatters:
              precise:
                format: '%(asctime)s - %(name)s - %(lineno)d - %(levelname)s - %(request)s - %(message)s'
            handlers:
              console:
                class: logging.StreamHandler
                formatter: precise
            loggers:
              synapse.storage.SQL:
                level: INFO
              synapse.access.http.8008:
                level: INFO
            root:
              level: INFO
              handlers: [console]
            disable_existing_loggers: false
      '';
    }

    {
      name = "matrix/synapse-pvc.yaml";
      content = ''
        apiVersion: v1
        kind: PersistentVolumeClaim
        metadata:
          name: synapse-media
          namespace: ${mns}
          annotations:
            argocd.argoproj.io/sync-wave: "3"
        spec:
          accessModes: [ReadWriteOnce]
          storageClassName: local-path
          resources:
            requests:
              storage: ${toString m.mediaStorageGi}Gi
      '';
    }

    {
      name = "matrix/synapse-deployment.yaml";
      content = ''
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: synapse
          namespace: ${mns}
          annotations:
            argocd.argoproj.io/sync-wave: "4"
        spec:
          replicas: 1
          strategy:
            type: Recreate
          selector:
            matchLabels:
              app: synapse
          template:
            metadata:
              labels:
                app: synapse
            spec:
              nodeSelector:
                kubernetes.io/hostname: k8s-w3
              tolerations:
              - key: node-role.kubernetes.io/control-plane
                operator: Exists
                effect: NoSchedule
              initContainers:
              - name: generate-keys
                image: ${m.images.synapse}
                command:
                - sh
                - -c
                - |
                  set -e
                  mkdir -p /data/media_store /data/uploads
                  if [ ! -f /data/signing.key ]; then
                    echo "Generating Synapse signing key..."
                    python -m synapse.app.homeserver \
                      --config-path /etc/synapse/homeserver.yaml \
                      --config-path /etc/synapse-secrets/homeserver.secrets.yaml \
                      --generate-keys
                  else
                    echo "signing.key already present, skipping generation"
                  fi
                volumeMounts:
                - { name: data,        mountPath: /data }
                - { name: config,      mountPath: /etc/synapse }
                - { name: secrets,     mountPath: /etc/synapse-secrets, readOnly: true }
                - { name: appservices, mountPath: /etc/synapse/appservices, readOnly: true }
                env:
                - name: SYNAPSE_CONFIG_PATH
                  value: /etc/synapse/homeserver.yaml
              containers:
              - name: synapse
                image: ${m.images.synapse}
                command:
                - python
                - -m
                - synapse.app.homeserver
                - --config-path=/etc/synapse/homeserver.yaml
                - --config-path=/etc/synapse-secrets/homeserver.secrets.yaml
                ports:
                - { name: http, containerPort: 8008 }
                livenessProbe:
                  httpGet: { path: /health, port: 8008 }
                  initialDelaySeconds: 30
                  periodSeconds: 10
                  timeoutSeconds: 5
                readinessProbe:
                  httpGet: { path: /health, port: 8008 }
                  initialDelaySeconds: 10
                  periodSeconds: 5
                  timeoutSeconds: 3
                resources:
                  requests: { cpu: 200m, memory: 512Mi }
                  limits:   { cpu: 2000m, memory: 2Gi }
                volumeMounts:
                - { name: data,        mountPath: /data }
                - { name: config,      mountPath: /etc/synapse }
                - { name: secrets,     mountPath: /etc/synapse-secrets, readOnly: true }
                - { name: appservices, mountPath: /etc/synapse/appservices, readOnly: true }
              volumes:
              - name: data
                persistentVolumeClaim: { claimName: synapse-media }
              - name: config
                configMap:
                  name: synapse-config
                  items:
                  - { key: homeserver.yaml, path: homeserver.yaml }
                  - { key: log.config,      path: log.config }
              - name: secrets
                secret:
                  secretName: matrix-secrets
                  items:
                  - { key: homeserver.secrets.yaml, path: homeserver.secrets.yaml }
              - name: appservices
                projected:
                  sources:
                  - configMap:
                      name: hookshot-registration
                      items: [{ key: registration.yaml, path: hookshot.yaml }]
                  - configMap:
                      name: maubot-registration
                      items: [{ key: registration.yaml, path: maubot.yaml }]
                  - configMap:
                      name: mautrix-discord-registration
                      items: [{ key: registration.yaml, path: mautrix-discord.yaml }]
      '';
    }

    {
      name = "matrix/synapse-service.yaml";
      content = ''
        apiVersion: v1
        kind: Service
        metadata:
          name: synapse
          namespace: ${mns}
          annotations:
            argocd.argoproj.io/sync-wave: "4"
        spec:
          type: ClusterIP
          selector: { app: synapse }
          ports:
          - { name: http, port: 8008, targetPort: 8008 }
        ---
        apiVersion: v1
        kind: Service
        metadata:
          name: synapse-admin-nodeport
          namespace: ${mns}
          annotations:
            argocd.argoproj.io/sync-wave: "4"
        spec:
          type: NodePort
          selector: { app: synapse }
          ports:
          - name: http
            port: 8008
            targetPort: 8008
            nodePort: ${toString m.synapseAdminNodePort}
      '';
    }
  ];
}
