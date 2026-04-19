# nix/gitops/matrix/shared.nix
#
# Shared resources across all Matrix components: CNPG Database CRs (so
# Synapse and maubot get their own logical DBs inside the existing `pg`
# cluster), the self-signed lab Certificate that covers every Matrix
# hostname, and one Ingress with a rule per public host.
#
# Secrets (Synapse macaroon/form/registration; appservice AS/HS tokens;
# DB passwords) are NOT generated here — the operator creates them once
# with the helper in docs/matrix.md. This keeps the committed manifests
# free of random state and avoids the complexity of a self-mutating Job.
#
{ constants }:
let
  m   = constants.matrix;
  mns = "matrix";
in
{
  manifests = [
    # ─── CNPG Databases (logical DBs inside the existing `pg` cluster) ─
    # The CNPG Database CR (v1.25+) lets us declare "database X with
    # owner Y" against an existing Cluster. The operator creates the
    # role + database + grants owner to the role. Credentials are
    # sourced from the Secret named in `spec.owner`'s matching role
    # secret (CNPG auto-creates `<cluster>-<role>` Secrets when the
    # role is managed via the Cluster's `managed.roles` spec).
    #
    # For phase-1 simplicity we point each Database at the existing
    # app-owner role (`app`) — both Synapse and maubot share the
    # `app`-level credentials but land in separate logical DBs.
    # Phase-2 / production should migrate to dedicated per-app roles.
    {
      name = "matrix/databases.yaml";
      content = ''
        apiVersion: postgresql.cnpg.io/v1
        kind: Database
        metadata:
          name: synapse
          namespace: postgres
          annotations:
            argocd.argoproj.io/sync-wave: "1"
        spec:
          name: synapse
          owner: app
          cluster:
            name: pg
          # Synapse REQUIRES these exact locale settings for hash
          # consistency across replicas and versions (documented in
          # synapse's postgres setup guide).
          encoding: UTF8
          localeCtype: C
          localeCollate: C
          template: template0
        ---
        apiVersion: postgresql.cnpg.io/v1
        kind: Database
        metadata:
          name: maubot
          namespace: postgres
          annotations:
            argocd.argoproj.io/sync-wave: "1"
        spec:
          name: maubot
          owner: app
          cluster:
            name: pg
          encoding: UTF8
          template: template0
        ---
        apiVersion: postgresql.cnpg.io/v1
        kind: Database
        metadata:
          name: hookshot
          namespace: postgres
          annotations:
            argocd.argoproj.io/sync-wave: "1"
        spec:
          name: hookshot
          owner: app
          cluster:
            name: pg
          encoding: UTF8
          template: template0
      '';
    }

    # ─── Self-signed cert covering all Matrix hostnames (phase 1) ─────
    # Phase-2: swap issuerRef to `letsencrypt-prod-dns01` + add real
    # DNS-resolving hostnames. The Ingress below references this Secret
    # via `tls.secretName`.
    {
      name = "matrix/certificate.yaml";
      content = ''
        apiVersion: cert-manager.io/v1
        kind: Certificate
        metadata:
          name: matrix-tls
          namespace: ${mns}
          annotations:
            argocd.argoproj.io/sync-wave: "2"
        spec:
          secretName: matrix-tls
          duration: 2160h   # 90 days (matches future LE)
          renewBefore: 720h # 30 days
          privateKey:
            algorithm: ECDSA
            size: 256
          dnsNames:
          - ${m.serverName}
          - ${m.elementHost}
          - ${m.hookshotHost}
          - ${m.maubotHost}
          issuerRef:
            name: selfsigned-lab
            kind: ClusterIssuer
            group: cert-manager.io
      '';
    }

    # ─── Ingress (one resource, four rules) ────────────────────────────
    # Route /_matrix, /_synapse, /.well-known → Synapse; / → Element on
    # the element host; /webhook → hookshot; / → maubot on the maubot host.
    {
      name = "matrix/ingress.yaml";
      content = ''
        apiVersion: networking.k8s.io/v1
        kind: Ingress
        metadata:
          name: matrix
          namespace: ${mns}
          annotations:
            cert-manager.io/cluster-issuer: selfsigned-lab
            nginx.ingress.kubernetes.io/proxy-body-size: "50m"
            nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
            nginx.ingress.kubernetes.io/proxy-send-timeout: "600"
            argocd.argoproj.io/sync-wave: "5"
        spec:
          ingressClassName: nginx
          tls:
          - hosts:
            - ${m.serverName}
            - ${m.elementHost}
            - ${m.hookshotHost}
            - ${m.maubotHost}
            secretName: matrix-tls
          rules:
          # Synapse: homeserver client + (phase-2) federation API, plus
          # .well-known delegation. Federation paths served by the same
          # container in phase 1 even though federation is disabled in
          # homeserver.yaml — lets us flip the switch without re-routing.
          - host: ${m.serverName}
            http:
              paths:
              - path: /_matrix
                pathType: Prefix
                backend:
                  service:
                    name: synapse
                    port: { number: 8008 }
              - path: /_synapse
                pathType: Prefix
                backend:
                  service:
                    name: synapse
                    port: { number: 8008 }
              - path: /.well-known/matrix
                pathType: Prefix
                backend:
                  service:
                    name: synapse
                    port: { number: 8008 }
          # Element Web (community UI).
          - host: ${m.elementHost}
            http:
              paths:
              - path: /
                pathType: Prefix
                backend:
                  service:
                    name: element
                    port: { number: 80 }
          # Hookshot webhooks — GitHub/GitLab/Jira POST here.
          - host: ${m.hookshotHost}
            http:
              paths:
              - path: /
                pathType: Prefix
                backend:
                  service:
                    name: hookshot
                    port: { number: 9000 }
          # Maubot management UI.
          - host: ${m.maubotHost}
            http:
              paths:
              - path: /
                pathType: Prefix
                backend:
                  service:
                    name: maubot
                    port: { number: 29316 }
      '';
    }
  ];
}
