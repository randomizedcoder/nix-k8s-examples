# Matrix Chat System

A [Matrix](https://matrix.org/) homeserver stack for hosting an open-source
community: human chat, automation bots, webhook integrations, and one
cross-community IM bridge.

## Stack

| Layer | Component | Purpose |
|---|---|---|
| Homeserver | **Synapse** | Reference Matrix server. Stores rooms/events in Postgres, media on PVC. |
| Web client | **Element Web** | Official browser client. Served from `element.lab.local`. |
| Webhooks | **matrix-hookshot** | Ingests GitHub / GitLab / Jira / generic webhooks into rooms. |
| Bots | **maubot** | Web-UI-driven bot host; install plugins (reminder, RSS, karma, sed, …) without writing code. |
| IM bridge | **mautrix-discord** | Day-1 Discord ↔ Matrix bridge. |
| Ingress | **Cilium Ingress** (Envoy) on L2-announced VIP `10.33.33.50` | Single LoadBalancer Service; one node at a time ARP-replies for the VIP. Phase-2 swaps L2 for BGP — same VIP. |
| TLS | **cert-manager** (`selfsigned-lab` ClusterIssuer) | Phase-1 lab CA. Phase-2 flips to Let's Encrypt DNS-01. |
| Database | **CNPG** `synapse`, `maubot`, `hookshot`, `mautrix_discord` `Database` CRs inside the existing `pg` cluster | HA for free via the existing Postgres HA. |

## Phase 1 (lab) vs Phase 2 (public)

Phase 1 is what this PR ships. Phase 2 is documented as toggles, not
implemented.

| Aspect | Phase 1 (now) | Phase 2 (future) |
|---|---|---|
| `server_name` | `matrix.lab.local` (permanent — see "server_name is forever" below) | Same value (permanent); client/federation reachable via DNS + `.well-known` delegation |
| Ingress frontend | Cilium Ingress (Envoy) + LoadBalancer on VIP `10.33.33.50` (L2-announced to the lab bridge) | Same VIP, same Service, same Ingress — just flip Cilium from `l2announcements` to `bgpControlPlane` |
| TLS | `selfsigned-lab` ClusterIssuer (self-signed ECDSA CA) | `letsencrypt-prod-dns01` (stub already in repo; needs DNS-01 credentials secret) |
| Federation | Off (`federation = false` in `constants.nix`) | On; `.well-known/matrix/server` served from a ConfigMap behind the same Cilium Ingress |
| DNS | `/etc/hosts` maps `*.lab.local → 10.33.33.50` (Cilium VIP) | Public DNS A/AAAA records point at the anycast VIP |

Phase-2 cutover — note the permanence caveat below — requires wiping the
Synapse database so keys/events re-sign under a reachable public hostname.

## server_name is forever

Matrix bakes `server_name` into every signed event and every user ID
(`@alice:matrix.lab.local`). You cannot rename it without abandoning the
database. The cluster commits to `matrix.lab.local` for the lab phase; going
public later means **fresh Synapse DB, re-register users, re-create rooms**.
Plan accordingly.

## Bootstrapping secrets

Synapse, hookshot, maubot, and mautrix-discord each need secrets that cannot
live in git: macaroon / form / registration secrets, appservice tokens, the
Postgres password, and a bcrypt'd maubot admin password. A one-shot helper
generates them and stores them in the cluster:

```bash
# Optional: stash the maubot admin password outside the repo so the
# bootstrap runs non-interactively. File must be chmod 600 and owned
# by you; the script refuses anything laxer.
umask 077
cat > ~/.ssh/nix-k8s-examples-secrets <<'EOF'
MAUBOT_ADMIN="your-maubot-admin-password"
EOF
chmod 600 ~/.ssh/nix-k8s-examples-secrets

# Generates 10 hex tokens, pulls the pg 'app' password live from the
# cluster's pg-app Secret, reads MAUBOT_ADMIN from the file above (or
# prompts if absent), bcrypts it, and writes the matrix-secrets K8s
# Secret.
nix run .#k8s-matrix-bootstrap-secrets
```

The helper refuses to overwrite an existing `matrix-secrets`; pass `--force`
to rotate. ArgoCD ignores diffs on the registration ConfigMaps (`/data`
jsonPointer) so the operator can paste the real AS tokens in without the
sync reverting them.

After running the bootstrap, patch the three `*-registration` ConfigMaps
with the real tokens printed to the console:

```bash
# Example — hookshot. Repeat for maubot, mautrix-discord using their
# respective AS/HS tokens from the matrix-secrets Secret.
kubectl -n matrix edit configmap hookshot-registration
#   as_token: <REPLACE_ME_AS>  -> paste hookshot_as_token
#   hs_token: <REPLACE_ME_HS>  -> paste hookshot_hs_token
```

Restart the affected Deployments after editing.

## Add a user

Registration is closed. The operator creates users via Synapse's admin API:

```bash
nix run .#k8s-matrix-register-user -- --username=alice
# Prompts for password (twice)
# Add --admin for an admin-capable account
```

Under the hood: fetches the `registration_shared_secret` from the
`matrix-secrets` Secret, calls the admin nonce+MAC flow against the
Synapse admin NodePort (30800 on any node IP).

## Log in from the lab host

1. Edit `/etc/hosts` on the host machine:

   ```
   10.33.33.50 matrix.lab.local element.lab.local hookshot.lab.local maubot.lab.local
   ```

   (`10.33.33.50` is the Cilium Ingress VIP — announced via L2/ARP from
   whichever cluster node currently holds the L2 lease. The host reaches
   it directly over the `k8sbr0` bridge, no host-side haproxy fanout.)

2. Trust the lab CA (or accept the browser prompt once):

   ```bash
   kubectl -n cert-manager get secret selfsigned-lab-ca -o jsonpath='{.data.ca\.crt}' \
     | base64 -d > /tmp/lab-ca.pem
   # Optional: install into your browser's trust store.
   ```

3. Open <https://element.lab.local> and log in as the user you created.

## Add a bridge

The Discord bridge is day-1. To add another (IRC, Slack, Telegram, …):

1. Create `nix/gitops/matrix/<bridge>.nix` modelled on
   `nix/gitops/matrix/mautrix-discord.nix` — it's a ConfigMap for config,
   a ConfigMap for `registration.yaml` (ArgoCD-ignored on `/data`), a
   Deployment mounting both, a Service, and an entry in the shared
   `app_service_config_files` list in `homeserver.yaml`.
2. Add the bridge's `Database` CR to `nix/gitops/matrix/shared.nix` if it
   needs Postgres.
3. Add it to the imports in `nix/gitops/env/matrix.nix`.
4. Generate its AS/HS tokens in `nix/matrix-scripts.nix` → `bootstrapSecrets`,
   and rotate: `nix run .#k8s-matrix-bootstrap-secrets -- --force`.
5. `nix run .#k8s-render-manifests && git add rendered/ nix/ && git commit`.

## Add a hookshot listener

`hookshot-config` ConfigMap has `generic` and `feeds` listeners enabled;
GitHub / GitLab / Jira are commented out. To enable GitHub:

1. Edit `nix/gitops/matrix/hookshot.nix`: uncomment the `github:` block
   in `config.yml`, paste the GitHub App private key into
   `matrix-secrets` as `hookshot_github_privatekey`, mount it into the
   Deployment as a file.
2. In the target room, `/invite @hookshot:matrix.lab.local`, then from
   the bot `!hookshot github repo owner/repo`.
3. Point the GitHub webhook at
   `https://hookshot.lab.local/webhook/` (payload URL shown by the bot).

## Phase-1 → Phase-2 cutover

When public IPs + anycast VIP + public DNS are in place:

1. **Decide**: accept `matrix.lab.local` as the permanent public name, or
   pick a new one (requires wiping the Synapse DB).
2. `constants.nix`: `matrix.federation = true`; update `matrix.serverName`
   iff going with a new public name.
3. Flip Cilium from L2 announcements to BGP: disable `l2announcements`,
   enable `bgpControlPlane`, add a `CiliumBGPPeeringPolicy` alongside the
   existing `CiliumLoadBalancerIPPool`. Same VIP, same Service, same
   Ingress — nothing on the Matrix side changes.
4. `nix/gitops/env/cert-manager.nix`: uncomment the
   `letsencrypt-prod-dns01` ClusterIssuer + the DNS-01 credentials Secret
   (created out-of-band with your DNS provider's API token). Flip the
   `matrix-tls` Certificate's `issuerRef` to `letsencrypt-prod-dns01`.
5. Add a `.well-known/matrix/server` + `.well-known/matrix/client`
   ConfigMap routed through the same Cilium Ingress at
   `https://matrix.lab.local/.well-known/matrix/*`.
6. Re-render: `nix run .#k8s-render-manifests`.
7. Apply: ArgoCD syncs. Watch `kubectl -n matrix logs deploy/synapse`;
   federation handshake appears in logs once public traffic reaches it.

## Known limitations

- **Media store is node-local** — the Synapse PVC uses `local-path`
  pinned to `w3`. If `w3` is destroyed, uploaded images are gone.
  Same caveat as CNPG's local-path data; phase-2 migration to S3
  (`media_storage_providers: [s3_storage_provider]`) removes this.
- **Single-process Synapse** — no `generic_worker` / `federation_sender` /
  `media_repository` workers, no Redis. Fine for community sizes up to
  low thousands of MAU. Add workers + Redis when a bottleneck shows up.
- **No TURN / voice / video** — deferred; add coturn + Synapse
  `turn_uris` config in a later PR.
- **Appservice tokens are hand-patched** — the bootstrap script creates
  them in the Secret but does not patch them into the
  `*-registration` ConfigMaps automatically (ArgoCD would race). Manual
  `kubectl edit` after `bootstrapSecrets`. Tokens never need to rotate
  unless compromised.

## Verification

```bash
# Pods healthy
kubectl -n matrix get pods
# → synapse, element-web, hookshot, maubot, mautrix-discord all 1/1 Running

# Databases provisioned by CNPG
kubectl -n postgres get database.postgresql.cnpg.io
# → synapse, maubot, hookshot, mautrix_discord all Status=Ready

# Synapse client API reachable via haproxy VIP
curl -kv https://matrix.lab.local/_matrix/client/versions | jq .versions

# ArgoCD sees the app
kubectl -n argocd get application matrix
# → SYNC STATUS=Synced  HEALTH STATUS=Healthy
```

## File layout

```
nix/gitops/env/matrix.nix        Aggregator (imports the matrix/ sub-modules + ArgoCD Application)
nix/gitops/matrix/shared.nix     CNPG Database CRs, matrix-tls Certificate, single Ingress with 4 hosts
nix/gitops/matrix/synapse.nix    Synapse Deployment + ConfigMaps + PVC + Services (ClusterIP + admin NodePort)
nix/gitops/matrix/element.nix    Element Web Deployment + Service
nix/gitops/matrix/hookshot.nix   matrix-hookshot Deployment + registration/config ConfigMaps + Service
nix/gitops/matrix/maubot.nix     maubot Deployment + plugins PVC + config ConfigMap + Service
nix/gitops/matrix/mautrix-discord.nix   mautrix-discord Deployment + registration/config ConfigMaps + Service
nix/matrix-scripts.nix           Operator helpers: k8s-matrix-register-user, k8s-matrix-bootstrap-secrets
```

## Future extensions

Captured here so they don't get lost:

- coturn for voice/video (UDP 3478).
- Synapse workers + Redis when MAU > ~1k or federation lag appears.
- Media store migration to S3 (MinIO in-cluster or external).
- Additional bridges: IRC, Slack, Telegram.
- Hookshot expansion: Prometheus Alertmanager → Matrix room alerts.
- synapse-admin web UI.
- Chaos-test coverage for Matrix components (round-trip probe during
  SIGKILL rotation).
- Turnkey Matrix Space with pre-created rooms (#general, #dev, #alerts,
  #github-feed) via an init Job using the admin API.
