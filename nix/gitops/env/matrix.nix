# nix/gitops/env/matrix.nix
#
# Matrix homeserver for the OSS community chat.
#
# This file is the aggregator — five sub-modules under ../matrix/ each
# own one component so individual pieces stay reviewable:
#
#   shared.nix          — CNPG Databases, TLS cert, the one Ingress
#                         that routes every Matrix hostname.
#   synapse.nix         — homeserver (Python), the Matrix protocol entry.
#   element.nix         — official web client served over the Ingress.
#   hookshot.nix        — GitHub / GitLab / Jira / generic webhooks.
#   maubot.nix          — Python bot framework with web-UI plugin loader.
#   mautrix-discord.nix — Discord bridge (day-1 default; swap for IRC /
#                         Slack / Telegram by replacing this one file).
#
# All operator-generated secrets (signing key stays on-PVC; macaroon /
# form / registration shared secrets, appservice tokens, DB passwords,
# maubot admin bcrypt) live in a single Secret `matrix-secrets` in the
# `matrix` namespace, NOT committed to git. Create-once procedure in
# docs/matrix.md.
#
# Phase-1 (lab) ↔ phase-2 (public, federated, BGP anycast) cutover is
# driven by a few constants.nix flags plus a fresh Synapse DB (server_name
# is baked into every signed event and can't be renamed). See
# docs/matrix.md.
#
{ pkgs, lib }:
let
  constants = import ../../constants.nix;

  shared         = import ../matrix/shared.nix          { inherit constants; };
  synapse        = import ../matrix/synapse.nix         { inherit constants; };
  element        = import ../matrix/element.nix         { inherit constants; };
  hookshot       = import ../matrix/hookshot.nix        { inherit constants; };
  maubot         = import ../matrix/maubot.nix          { inherit constants; };
  mautrixDiscord = import ../matrix/mautrix-discord.nix { inherit constants; };
in
{
  manifests =
    shared.manifests
    ++ synapse.manifests
    ++ element.manifests
    ++ hookshot.manifests
    ++ maubot.manifests
    ++ mautrixDiscord.manifests
    ++ [
      {
        name = "matrix/application.yaml";
        content = ''
          apiVersion: argoproj.io/v1alpha1
          kind: Application
          metadata:
            name: matrix
            namespace: argocd
          spec:
            project: default
            source:
              repoURL: ${constants.gitops.repoURL}
              targetRevision: ${constants.gitops.targetRevision}
              path: ${constants.gitops.renderedPath}/matrix
              directory:
                recurse: false
                exclude: 'application.yaml'
            destination:
              server: https://kubernetes.default.svc
            syncPolicy:
              automated:
                prune: true
                selfHeal: true
              syncOptions:
                - ServerSideApply=true
                - CreateNamespace=true
                - RespectIgnoreDifferences=true
            ignoreDifferences:
              # Appservice registration tokens are operator-rotated after
              # deploy — don't let ArgoCD revert them to REPLACE_ME.
              - group: ""
                kind: ConfigMap
                name: hookshot-registration
                namespace: matrix
                jsonPointers: ["/data"]
              - group: ""
                kind: ConfigMap
                name: hookshot-config
                namespace: matrix
                jsonPointers: ["/data"]
              - group: ""
                kind: ConfigMap
                name: maubot-registration
                namespace: matrix
                jsonPointers: ["/data"]
              - group: ""
                kind: ConfigMap
                name: maubot-config
                namespace: matrix
                jsonPointers: ["/data"]
              - group: ""
                kind: ConfigMap
                name: mautrix-discord-registration
                namespace: matrix
                jsonPointers: ["/data"]
              - group: ""
                kind: ConfigMap
                name: mautrix-discord-config
                namespace: matrix
                jsonPointers: ["/data"]
        '';
      }
    ];
}
