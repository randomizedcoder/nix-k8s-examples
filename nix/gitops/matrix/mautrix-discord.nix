# nix/gitops/matrix/mautrix-discord.nix
#
# mautrix-discord — Discord ↔ Matrix bridge.
#
# Default day-1 IM bridge (chosen in plan; swap for mautrix-telegram /
# matrix-appservice-irc / matrix-appservice-slack by replacing this
# module). Registers as a Synapse appservice under namespace `@_discord_.*`.
#
# Login flow is per-user: operator uses `/login` in DMs with the bridge
# bot after deploy; see docs/matrix.md.
#
{ constants }:
let
  m   = constants.matrix;
  mns = "matrix";
in
{
  manifests = [
    {
      name = "matrix/mautrix-discord-registration.yaml";
      content = ''
        apiVersion: v1
        kind: ConfigMap
        metadata:
          name: mautrix-discord-registration
          namespace: ${mns}
          annotations:
            argocd.argoproj.io/sync-wave: "3"
            argocd.argoproj.io/compare-options: IgnoreExtraneous
        data:
          registration.yaml: |
            id: discord
            url: http://mautrix-discord.matrix.svc.cluster.local:29334
            as_token: REPLACE_ME_MAUTRIX_DISCORD_AS_TOKEN
            hs_token: REPLACE_ME_MAUTRIX_DISCORD_HS_TOKEN
            sender_localpart: discordbot
            rate_limited: false
            namespaces:
              users:
              - exclusive: true
                regex: "@_discord_.*"
              aliases:
              - exclusive: true
                regex: "#_discord_.*"
              rooms: []
            de.sorunome.msc2409.push_ephemeral: true
            push_ephemeral: true
      '';
    }

    {
      name = "matrix/mautrix-discord-config.yaml";
      content = ''
        apiVersion: v1
        kind: ConfigMap
        metadata:
          name: mautrix-discord-config
          namespace: ${mns}
          annotations:
            argocd.argoproj.io/sync-wave: "3"
            argocd.argoproj.io/compare-options: IgnoreExtraneous
        data:
          config.yaml: |
            homeserver:
              address: http://synapse.matrix.svc.cluster.local:8008
              domain: ${m.serverName}
              software: standard
              status_endpoint: null
              message_send_checkpoint_endpoint: null
              async_media: false
            appservice:
              address: http://mautrix-discord.matrix.svc.cluster.local:29334
              hostname: 0.0.0.0
              port: 29334
              database:
                type: postgres
                uri: postgresql://app@pg-rw.postgres.svc.cluster.local/mautrix_discord?sslmode=disable
                max_open_conns: 20
                max_idle_conns: 2
              id: discord
              bot:
                username: discordbot
                displayname: Discord bridge bot
                avatar: ""
              ephemeral_events: true
              as_token: REPLACE_ME_MAUTRIX_DISCORD_AS_TOKEN
              hs_token: REPLACE_ME_MAUTRIX_DISCORD_HS_TOKEN
            bridge:
              username_template: _discord_{{.}}
              displayname_template: '{{or .GlobalName .Username}} (Discord)'
              channel_name_template: '#{{.Name}}'
              guild_name_template: '{{.Name}}'
              command_prefix: '!dc'
              management_room_text:
                welcome: Hello, I'm the Discord bridge bot.
              portal_message_buffer: 128
              delivery_receipts: false
              message_status_events: false
              message_error_notices: true
              sync_direct_chat_list: false
              resend_bridge_info: false
              mute_bridging: false
              caption_in_message: false
              federate_rooms: false
              backfill:
                forward_limits:
                  initial: { dm: 0, channel: 0, thread: 0 }
                  missed:  { dm: 0, channel: 0, thread: 0 }
                max_guild_members: 0
              permissions:
                '*': relay
                ${m.serverName}: user
                '@admin:${m.serverName}': admin
            logging:
              min_level: info
              writers:
              - type: stdout
                format: pretty-colored
      '';
    }

    # Extra CNPG Database CR for mautrix-discord (shared.nix only creates
    # synapse + maubot + hookshot; this is the fourth).
    {
      name = "matrix/mautrix-discord-database.yaml";
      content = ''
        apiVersion: postgresql.cnpg.io/v1
        kind: Database
        metadata:
          name: mautrix-discord
          namespace: postgres
          annotations:
            argocd.argoproj.io/sync-wave: "1"
        spec:
          name: mautrix_discord
          owner: app
          cluster: { name: pg }
          encoding: UTF8
          template: template0
      '';
    }

    {
      name = "matrix/mautrix-discord-deployment.yaml";
      content = ''
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: mautrix-discord
          namespace: ${mns}
          annotations:
            argocd.argoproj.io/sync-wave: "6"
        spec:
          replicas: 1
          strategy: { type: Recreate }
          selector:
            matchLabels: { app: mautrix-discord }
          template:
            metadata:
              labels: { app: mautrix-discord }
            spec:
              tolerations:
              - key: node-role.kubernetes.io/control-plane
                operator: Exists
                effect: NoSchedule
              containers:
              - name: mautrix-discord
                image: ${m.images.mautrixDiscord}
                ports:
                - { name: appservice, containerPort: 29334 }
                readinessProbe:
                  tcpSocket: { port: 29334 }
                  initialDelaySeconds: 10
                  periodSeconds: 10
                resources:
                  requests: { cpu: 50m,  memory: 128Mi }
                  limits:   { cpu: 500m, memory: 512Mi }
                volumeMounts:
                - { name: config, mountPath: /data/config.yaml, subPath: config.yaml, readOnly: true }
                - { name: reg,    mountPath: /data/registration.yaml, subPath: registration.yaml, readOnly: true }
              volumes:
              - name: config
                configMap:
                  name: mautrix-discord-config
                  items: [{ key: config.yaml, path: config.yaml }]
              - name: reg
                configMap:
                  name: mautrix-discord-registration
                  items: [{ key: registration.yaml, path: registration.yaml }]
      '';
    }

    {
      name = "matrix/mautrix-discord-service.yaml";
      content = ''
        apiVersion: v1
        kind: Service
        metadata:
          name: mautrix-discord
          namespace: ${mns}
          annotations:
            argocd.argoproj.io/sync-wave: "6"
        spec:
          type: ClusterIP
          selector: { app: mautrix-discord }
          ports:
          - { name: appservice, port: 29334, targetPort: 29334 }
      '';
    }
  ];
}
