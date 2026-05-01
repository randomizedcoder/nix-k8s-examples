# nix/gitops/env/registry.nix
#
# In-cluster OCI registry (Zot). Lets Nix-built images — starting
# with hubble-otel from the archived cilium/hubble-otel tree — be
# pushed from the dev box and pulled by containerd without any
# public-registry hop.
#
# Topology:
#
#                 push (skopeo, authenticated via htpasswd)
#   dev box ─────────────────────────────────────────────────────┐
#                                                                │
#   ┌──── registry.lab.local ────────────────────────────────────┤
#   │                                                            │
#   │   LoadBalancer Service (10.33.33.51:443)                   │
#   │     └─ scoped CiliumLoadBalancerIPPool + L2 policy         │
#   │          (serviceSelector: app=zot — does not contend      │
#   │           with cilium-ingress at .50)                      │
#   │   │                                                        │
#   │   ↓                                                        │
#   │   Deployment (zot:5000, TLS terminated by Zot)             │
#   │     – cert/key mounted via hostPath from the node PKI      │
#   │       bundle (registry-tls.{crt,key}, signed by cluster CA)│
#   │     – htpasswd Secret mounted for push auth                │
#   │     – anonymous pull allowed, push requires htpasswd       │
#   │     – PVC (local-path, 5Gi) for blob store                 │
#   │                                                            │
#   └────────────────────────────────────────────────────────────┘
#         ↑
#         │ pull (containerd, unauthenticated, CA from /var/lib/kubernetes/pki/ca.crt)
#     every node
#
# Secrets (registry-htpasswd) live outside git — see
# `nix run .#k8s-registry-bootstrap-secrets`.
#
{ pkgs, lib }:
let
  constants = import ../../constants.nix;
  r = constants.registry;

  # Zot config: anonymous pull + htpasswd-gated push, TLS on the
  # listener (the LB is a pass-through L4 Service). Paths align with
  # the volumeMounts in the Deployment below.
  zotConfig = ''
    {
      "distSpecVersion": "1.1.0",
      "storage": {
        "rootDirectory": "/var/lib/registry"
      },
      "http": {
        "address": "0.0.0.0",
        "port": "${toString r.zotPort}",
        "tls": {
          "cert": "/etc/zot/tls/tls.crt",
          "key":  "/etc/zot/tls/tls.key"
        },
        "auth": {
          "htpasswd": {
            "path": "/etc/zot/auth/htpasswd"
          }
        },
        "accessControl": {
          "repositories": {
            "**": {
              "anonymousPolicy": ["read"],
              "policies": [
                {
                  "users": ["${r.pushUser}"],
                  "actions": ["read", "create", "update", "delete"]
                }
              ]
            }
          }
        }
      },
      "log": {
        "level": "info"
      }
    }
  '';
in
{
  manifests = [
    {
      name = "registry/namespace.yaml";
      content = ''
        apiVersion: v1
        kind: Namespace
        metadata:
          name: ${r.namespace}
      '';
    }

    # ─── Zot config ───────────────────────────────────────────────────
    {
      name = "registry/configmap.yaml";
      content = ''
        apiVersion: v1
        kind: ConfigMap
        metadata:
          name: zot-config
          namespace: ${r.namespace}
        data:
          config.json: |
        ${lib.concatMapStrings (l: "    ${l}\n") (lib.splitString "\n" zotConfig)}
      '';
    }

    # ─── Placeholder htpasswd Secret ──────────────────────────────────
    # Bootstrap script rewrites this with a real bcrypted entry for
    # `pushUser`. Listed in the ArgoCD Application's ignoreDifferences
    # so self-heal does not clobber the real value.
    {
      name = "registry/secret-htpasswd.yaml";
      content = ''
        apiVersion: v1
        kind: Secret
        metadata:
          name: registry-htpasswd
          namespace: ${r.namespace}
        type: Opaque
        stringData:
          htpasswd: "__BOOTSTRAPPED_OUT_OF_BAND__"
      '';
    }

    # ─── Blob store PVC ───────────────────────────────────────────────
    {
      name = "registry/pvc.yaml";
      content = ''
        apiVersion: v1
        kind: PersistentVolumeClaim
        metadata:
          name: zot-storage
          namespace: ${r.namespace}
        spec:
          accessModes:
          - ReadWriteOnce
          storageClassName: "local-path"
          resources:
            requests:
              storage: ${toString r.storageGi}Gi
      '';
    }

    # ─── Zot Deployment ───────────────────────────────────────────────
    # TLS cert/key come from the node PKI dir via hostPath (baked at
    # VM build time, rotated with the rest of the cluster PKI).
    {
      name = "registry/deployment.yaml";
      content = ''
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: zot
          namespace: ${r.namespace}
        spec:
          # local-path PVC is RWO → single replica.
          replicas: 1
          strategy:
            type: Recreate
          selector:
            matchLabels:
              app: zot
          template:
            metadata:
              labels:
                app: zot
            spec:
              containers:
              - name: zot
                image: ${r.image}
                args: ["serve", "/etc/zot/config.json"]
                ports:
                - name: https
                  containerPort: ${toString r.zotPort}
                volumeMounts:
                - name: config
                  mountPath: /etc/zot/config.json
                  subPath: config.json
                - name: tls
                  mountPath: /etc/zot/tls
                  readOnly: true
                - name: auth
                  mountPath: /etc/zot/auth
                  readOnly: true
                - name: storage
                  mountPath: /var/lib/registry
                readinessProbe:
                  httpGet:
                    path: /v2/
                    port: ${toString r.zotPort}
                    scheme: HTTPS
                  initialDelaySeconds: 2
                  periodSeconds: 5
                livenessProbe:
                  httpGet:
                    path: /v2/
                    port: ${toString r.zotPort}
                    scheme: HTTPS
                  initialDelaySeconds: 10
                  periodSeconds: 30
                resources:
                  requests:
                    cpu: 50m
                    memory: 64Mi
                  limits:
                    cpu: 500m
                    memory: 512Mi
              volumes:
              - name: config
                configMap:
                  name: zot-config
              # TLS cert + key are populated into the registry-tls
              # Secret by the bootstrap script (it reads the
              # cluster-CA-signed leaf from the node PKI dir over
              # SSH). Mounting via Secret rather than hostPath means
              # the Deployment is not pinned to a specific node.
              - name: tls
                secret:
                  secretName: registry-tls
                  items:
                  - key: tls.crt
                    path: tls.crt
                  - key: tls.key
                    path: tls.key
              - name: auth
                secret:
                  secretName: registry-htpasswd
                  items:
                  - key: htpasswd
                    path: htpasswd
              - name: storage
                persistentVolumeClaim:
                  claimName: zot-storage
      '';
    }

    # ─── registry-tls Secret: bridges node hostPath → pod ─────────────
    # The cert + key live on every node under /var/lib/kubernetes/pki/.
    # A plain hostPath mount would bind the Deployment to a specific
    # node; instead we surface them via a Secret populated at bootstrap
    # time (the bootstrap script reads the files over SSH and writes
    # the Secret). Listed in ignoreDifferences so self-heal does not
    # blank the real cert.
    {
      name = "registry/secret-tls.yaml";
      content = ''
        apiVersion: v1
        kind: Secret
        metadata:
          name: registry-tls
          namespace: ${r.namespace}
        type: kubernetes.io/tls
        stringData:
          tls.crt: "__BOOTSTRAPPED_OUT_OF_BAND__"
          tls.key: "__BOOTSTRAPPED_OUT_OF_BAND__"
      '';
    }

    # ─── LoadBalancer Service ─────────────────────────────────────────
    # Pinned VIP — declared by a scoped CiliumLoadBalancerIPPool below
    # so cilium-ingress's allocation at .50 stays deterministic.
    {
      name = "registry/service.yaml";
      content = ''
        apiVersion: v1
        kind: Service
        metadata:
          name: zot
          namespace: ${r.namespace}
          labels:
            app: zot
        spec:
          type: LoadBalancer
          loadBalancerIP: ${r.vip}
          selector:
            app: zot
          ports:
          - name: https
            port: ${toString r.httpsPort}
            targetPort: ${toString r.zotPort}
            protocol: TCP
      '';
    }

    # ─── Scoped LB IP pool + L2 policy for the registry VIP ──────────
    # `serviceSelector` keeps the .51 pool strictly for the zot
    # Service — cilium-ingress can't accidentally pick up this IP.
    {
      name = "registry/lb-ip-pool.yaml";
      content = ''
        apiVersion: cilium.io/v2
        kind: CiliumLoadBalancerIPPool
        metadata:
          name: registry-lb-pool
        spec:
          serviceSelector:
            matchLabels:
              app: zot
          blocks:
          - start: "${r.vip}"
            stop:  "${r.vip}"
      '';
    }
    {
      name = "registry/l2-announcement-policy.yaml";
      content = ''
        apiVersion: cilium.io/v2alpha1
        kind: CiliumL2AnnouncementPolicy
        metadata:
          name: registry-l2
        spec:
          serviceSelector:
            matchLabels:
              app: zot
          interfaces:
          - ${constants.cilium.ingress.nic}
          externalIPs: true
          loadBalancerIPs: true
      '';
    }

    {
      name = "registry/application.yaml";
      content = ''
        apiVersion: argoproj.io/v1alpha1
        kind: Application
        metadata:
          name: registry
          namespace: argocd
        spec:
          project: default
          source:
            repoURL: ${constants.gitops.repoURL}
            targetRevision: ${constants.gitops.targetRevision}
            path: ${constants.gitops.renderedPath}/registry
            directory:
              exclude: 'application.yaml'
          destination:
            server: https://kubernetes.default.svc
            namespace: ${r.namespace}
          syncPolicy:
            automated:
              prune: true
              selfHeal: true
            syncOptions:
              - ServerSideApply=true
              - CreateNamespace=true
              - RespectIgnoreDifferences=true
          ignoreDifferences:
            # Bootstrap script rewrites these Secrets' data
            # out-of-band (htpasswd entry; TLS cert/key pulled from
            # the node PKI dir). Prevent ArgoCD from reverting them
            # back to the in-git placeholders on every self-heal.
            - group: ""
              kind: Secret
              name: registry-htpasswd
              namespace: ${r.namespace}
              jsonPointers: ["/data", "/stringData"]
            - group: ""
              kind: Secret
              name: registry-tls
              namespace: ${r.namespace}
              jsonPointers: ["/data", "/stringData"]
      '';
    }
  ];
}
