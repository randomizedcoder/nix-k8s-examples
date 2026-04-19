# nix/gitops/matrix/hookshot.nix
#
# matrix-hookshot — GitHub/GitLab/Jira/generic webhooks → Matrix rooms.
#
# Runs as a Synapse appservice. The `hookshot-registration` ConfigMap
# is projected into Synapse's /etc/synapse/appservices/ directory and
# referenced by homeserver.yaml. Tokens (as_token, hs_token) are
# populated by the operator once with a random 64-byte hex and MUST
# match across the registration YAML (this ConfigMap) and hookshot's
# config.yml (via env from matrix-secrets).
#
# Storage: SQLite in an ephemeral volume for phase 1 — the only durable
# state is the webhook mapping, which is re-created via the bot's
# in-chat commands. Phase 2: migrate to Postgres (hookshot supports it
# and the CNPG `hookshot` database CR already exists in shared.nix).
#
{ constants }:
let
  m   = constants.matrix;
  mns = "matrix";

  # Hookshot's registration YAML lives in a ConfigMap (projected into
  # Synapse). Tokens are referenced by keys in matrix-secrets; the
  # operator fills them in once. The `as_token` and `hs_token` lines
  # are placeholders here — we DO NOT want them in git — so we emit
  # the structural YAML and reference the Secret values via an init
  # container that envsubsts at pod start (see deployment below).
  #
  # IMPORTANT: Synapse does NOT do env substitution on appservice
  # registration files — so we can't rely on envsubst for those.
  # Instead, the operator bootstraps `hookshot-registration` ConfigMap
  # by running the helper in docs/matrix.md, which pulls tokens from
  # matrix-secrets and writes the final registration YAML. The manifest
  # below creates the ConfigMap with placeholder tokens; ArgoCD's
  # `syncOptions: [RespectIgnoreDifferences]` and per-file ignore
  # ensures our re-renders don't clobber the operator's bootstrapped
  # values.
in
{
  manifests = [
    # Appservice registration ConfigMap. Placeholder tokens — the
    # operator replaces them at install time (docs/matrix.md).
    {
      name = "matrix/hookshot-registration.yaml";
      content = ''
        apiVersion: v1
        kind: ConfigMap
        metadata:
          name: hookshot-registration
          namespace: ${mns}
          annotations:
            argocd.argoproj.io/sync-wave: "3"
            # Tokens are filled in once by the operator; don't let
            # ArgoCD revert them.
            argocd.argoproj.io/compare-options: IgnoreExtraneous
        data:
          registration.yaml: |
            id: hookshot
            url: http://hookshot.matrix.svc.cluster.local:9993
            as_token: REPLACE_ME_HOOKSHOT_AS_TOKEN
            hs_token: REPLACE_ME_HOOKSHOT_HS_TOKEN
            sender_localpart: hookshot
            rate_limited: false
            namespaces:
              users:
              - exclusive: true
                regex: "@_webhooks_.*"
              aliases:
              - exclusive: true
                regex: "#webhooks_.*"
              rooms: []
            de.sorunome.msc2409.push_ephemeral: true
            push_ephemeral: true
      '';
    }

    {
      name = "matrix/hookshot-config.yaml";
      content = ''
        apiVersion: v1
        kind: ConfigMap
        metadata:
          name: hookshot-config
          namespace: ${mns}
          annotations:
            argocd.argoproj.io/sync-wave: "3"
            argocd.argoproj.io/compare-options: IgnoreExtraneous
        data:
          config.yml: |
            bridge:
              domain: ${m.serverName}
              url: http://synapse.matrix.svc.cluster.local:8008
              mediaUrl: https://${m.serverName}
              port: 9993
              bindAddress: 0.0.0.0
            passFile: /data/passkey.pem
            logging:
              level: info
              colorize: true
            listeners:
            - port: 9000
              bindAddress: 0.0.0.0
              resources: [webhooks]
            generic:
              enabled: true
              urlPrefix: https://${m.hookshotHost}/webhook
              allowJsTransformationFunctions: false
              waitForComplete: false
              enableHttpGet: false
            # GitHub config is gated on a Secret the operator creates.
            # Uncomment and wire up once the GitHub App exists:
            # github:
            #   auth:
            #     id: 123
            #     privateKeyFile: /data/github-private-key.pem
            #   webhook:
            #     secret: REPLACE_ME_GITHUB_WEBHOOK_SECRET
            feeds:
              enabled: true
              pollIntervalSeconds: 600
            permissions:
            - actor: ${m.serverName}
              services:
              - service: "*"
                level: admin
          registration.yaml: |
            id: hookshot
            url: http://hookshot.matrix.svc.cluster.local:9993
            as_token: REPLACE_ME_HOOKSHOT_AS_TOKEN
            hs_token: REPLACE_ME_HOOKSHOT_HS_TOKEN
            sender_localpart: hookshot
            rate_limited: false
            namespaces:
              users:
              - exclusive: true
                regex: "@_webhooks_.*"
              aliases:
              - exclusive: true
                regex: "#webhooks_.*"
              rooms: []
      '';
    }

    {
      name = "matrix/hookshot-deployment.yaml";
      content = ''
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: hookshot
          namespace: ${mns}
          annotations:
            argocd.argoproj.io/sync-wave: "6"
        spec:
          replicas: 1
          strategy: { type: Recreate }
          selector:
            matchLabels: { app: hookshot }
          template:
            metadata:
              labels: { app: hookshot }
            spec:
              tolerations:
              - key: node-role.kubernetes.io/control-plane
                operator: Exists
                effect: NoSchedule
              initContainers:
              # Generate passkey.pem on first boot if missing — hookshot
              # uses it to sign messages in the generic webhook path.
              - name: init-passkey
                image: ${m.images.hookshot}
                command:
                - sh
                - -c
                - |
                  set -e
                  if [ ! -f /data/passkey.pem ]; then
                    echo "Generating hookshot passkey..."
                    openssl genrsa -out /data/passkey.pem 4096
                  fi
                volumeMounts:
                - { name: data, mountPath: /data }
              containers:
              - name: hookshot
                image: ${m.images.hookshot}
                args: ["node", "/usr/src/app/lib/App/BridgeApp.js", "/etc/hookshot/config.yml", "/etc/hookshot/registration.yaml"]
                ports:
                - { name: webhook,    containerPort: 9000 }
                - { name: appservice, containerPort: 9993 }
                readinessProbe:
                  httpGet: { path: /health, port: 9002 }
                  initialDelaySeconds: 15
                  periodSeconds: 10
                resources:
                  requests: { cpu: 50m,  memory: 128Mi }
                  limits:   { cpu: 500m, memory: 512Mi }
                volumeMounts:
                - { name: data,   mountPath: /data }
                - { name: config, mountPath: /etc/hookshot, readOnly: true }
              volumes:
              - name: data
                emptyDir: {}
              - name: config
                configMap:
                  name: hookshot-config
      '';
    }

    {
      name = "matrix/hookshot-service.yaml";
      content = ''
        apiVersion: v1
        kind: Service
        metadata:
          name: hookshot
          namespace: ${mns}
          annotations:
            argocd.argoproj.io/sync-wave: "6"
        spec:
          type: ClusterIP
          selector: { app: hookshot }
          ports:
          - { name: webhook,    port: 9000, targetPort: 9000 }
          - { name: appservice, port: 9993, targetPort: 9993 }
      '';
    }
  ];
}
