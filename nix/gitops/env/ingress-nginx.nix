# nix/gitops/env/ingress-nginx.nix
#
# ingress-nginx — the HTTP(S) reverse proxy in front of Matrix (Synapse,
# Element, hookshot, maubot).
#
# Layout choice: the upstream "cloud" deploy.yaml ships a single-replica
# Deployment behind a LoadBalancer Service (assumes a cloud LB). That
# doesn't fit this cluster — we want an ingress instance on EVERY node so
# the (phase-2) anycast VIP landing on any of the 4 public IPs reaches a
# local proxy. So we:
#
#   - Take the upstream deploy.yaml verbatim for the heavy parts (CRDs,
#     RBAC, ClusterRole, ValidatingWebhook, controller ConfigMap, etc.).
#   - Override it with our own DaemonSet + ClusterIP Service (controller)
#     + a patch that deletes the Deployment/LoadBalancer.
#
# The DaemonSet:
#   - binds hostPort 80 / 443 on every node — this is the future anycast
#     landing zone; in phase 1 the host-side haproxy at 10.33.33.1:443
#     fans to 10.33.33.10-13:443;
#   - tolerates the control-plane taint (same pattern as Cilium + CoreDNS);
#   - uses hostNetwork: false (hostPort is enough, no need to share the
#     node's netns);
#   - externalTrafficPolicy: Local — preserves client IP, avoids an extra
#     SNAT hop.
#
{ pkgs, lib }:
let
  constants = import ../../constants.nix;

  upstreamManifest = pkgs.fetchurl {
    url  = constants.ingressNginx.url;
    hash = constants.ingressNginx.hash;
  };

  # Strip the upstream Deployment + LoadBalancer Service; keep everything
  # else. The controller Deployment is named `ingress-nginx-controller`,
  # the LoadBalancer Service is named `ingress-nginx-controller` too but
  # differs by kind. We use `yq` at Nix build time to filter the stream.
  # Match both `kind` and `metadata.name` to avoid clobbering the admission
  # webhook service which has the same `ingress-nginx-controller-admission`
  # name prefix but a different exact name.
  filtered = pkgs.runCommand "ingress-nginx-filtered" {
    nativeBuildInputs = [ pkgs.yq-go ];
  } ''
    yq ea '
      select(
        .kind != "Deployment"
        and
        (.kind == "Service" and .metadata.name == "ingress-nginx-controller" | not)
      )
    ' ${upstreamManifest} > $out
  '';
in
{
  manifests = [
    # Upstream (minus the Deployment + LB Service we're replacing).
    {
      name = "ingress-nginx/upstream.yaml";
      source = "${filtered}";
    }

    # Our DaemonSet replacement.
    {
      name = "ingress-nginx/daemonset.yaml";
      content = ''
        apiVersion: apps/v1
        kind: DaemonSet
        metadata:
          name: ingress-nginx-controller
          namespace: ingress-nginx
          labels:
            app.kubernetes.io/name: ingress-nginx
            app.kubernetes.io/instance: ingress-nginx
            app.kubernetes.io/component: controller
          annotations:
            argocd.argoproj.io/sync-wave: "1"
        spec:
          selector:
            matchLabels:
              app.kubernetes.io/name: ingress-nginx
              app.kubernetes.io/instance: ingress-nginx
              app.kubernetes.io/component: controller
          updateStrategy:
            type: RollingUpdate
            rollingUpdate:
              maxUnavailable: 1
          minReadySeconds: 0
          template:
            metadata:
              labels:
                app.kubernetes.io/name: ingress-nginx
                app.kubernetes.io/instance: ingress-nginx
                app.kubernetes.io/component: controller
            spec:
              serviceAccountName: ingress-nginx
              dnsPolicy: ClusterFirstWithHostNet
              # Tolerate the CP taint — we want ingress on all 4 nodes.
              tolerations:
              - key: node-role.kubernetes.io/control-plane
                operator: Exists
                effect: NoSchedule
              - key: node-role.kubernetes.io/master
                operator: Exists
                effect: NoSchedule
              containers:
              - name: controller
                image: registry.k8s.io/ingress-nginx/controller:v1.11.3
                imagePullPolicy: IfNotPresent
                lifecycle:
                  preStop:
                    exec:
                      command: [/wait-shutdown]
                args:
                - /nginx-ingress-controller
                - --publish-service=$(POD_NAMESPACE)/ingress-nginx-controller
                - --election-id=ingress-nginx-leader
                - --controller-class=k8s.io/ingress-nginx
                - --ingress-class=nginx
                - --configmap=$(POD_NAMESPACE)/ingress-nginx-controller
                - --validating-webhook=:8443
                - --validating-webhook-certificate=/usr/local/certificates/cert
                - --validating-webhook-key=/usr/local/certificates/key
                - --watch-ingress-without-class=true
                - --enable-ssl-passthrough
                securityContext:
                  runAsNonRoot: true
                  runAsUser: 101
                  allowPrivilegeEscalation: false
                  capabilities:
                    drop: [ALL]
                    add: [NET_BIND_SERVICE]
                  readOnlyRootFilesystem: false
                env:
                - name: POD_NAME
                  valueFrom: { fieldRef: { fieldPath: metadata.name } }
                - name: POD_NAMESPACE
                  valueFrom: { fieldRef: { fieldPath: metadata.namespace } }
                - name: LD_PRELOAD
                  value: /usr/local/lib/libmimalloc.so
                livenessProbe:
                  httpGet: { path: /healthz, port: 10254, scheme: HTTP }
                  initialDelaySeconds: 10
                  periodSeconds: 10
                  timeoutSeconds: 1
                  successThreshold: 1
                  failureThreshold: 5
                readinessProbe:
                  httpGet: { path: /healthz, port: 10254, scheme: HTTP }
                  initialDelaySeconds: 10
                  periodSeconds: 10
                  timeoutSeconds: 1
                  successThreshold: 1
                  failureThreshold: 3
                ports:
                - name: http
                  containerPort: 80
                  hostPort: ${toString constants.ingress.hostPortHttp}
                  protocol: TCP
                - name: https
                  containerPort: 443
                  hostPort: ${toString constants.ingress.hostPortHttps}
                  protocol: TCP
                - name: webhook
                  containerPort: 8443
                  protocol: TCP
                volumeMounts:
                - name: webhook-cert
                  mountPath: /usr/local/certificates/
                  readOnly: true
                resources:
                  requests:
                    cpu: 100m
                    memory: 128Mi
              volumes:
              - name: webhook-cert
                secret:
                  secretName: ingress-nginx-admission
        ---
        apiVersion: v1
        kind: Service
        metadata:
          name: ingress-nginx-controller
          namespace: ingress-nginx
          labels:
            app.kubernetes.io/name: ingress-nginx
            app.kubernetes.io/instance: ingress-nginx
            app.kubernetes.io/component: controller
          annotations:
            argocd.argoproj.io/sync-wave: "1"
        spec:
          # ClusterIP (not LoadBalancer) — public reachability is via
          # hostPort on every node. externalTrafficPolicy=Local preserves
          # client source IPs for logs + federation.
          type: ClusterIP
          externalTrafficPolicy: Local
          ipFamilyPolicy: SingleStack
          ipFamilies: [IPv4]
          ports:
          - name: http
            port: 80
            protocol: TCP
            targetPort: http
          - name: https
            port: 443
            protocol: TCP
            targetPort: https
          selector:
            app.kubernetes.io/name: ingress-nginx
            app.kubernetes.io/instance: ingress-nginx
            app.kubernetes.io/component: controller
      '';
    }

    # ArgoCD Application.
    {
      name = "ingress-nginx/application.yaml";
      content = ''
        apiVersion: argoproj.io/v1alpha1
        kind: Application
        metadata:
          name: ingress-nginx
          namespace: argocd
        spec:
          project: default
          source:
            repoURL: ${constants.gitops.repoURL}
            targetRevision: ${constants.gitops.targetRevision}
            path: ${constants.gitops.renderedPath}/ingress-nginx
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
      '';
    }
  ];
}
