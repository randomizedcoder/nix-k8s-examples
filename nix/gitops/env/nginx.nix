# nix/gitops/env/nginx.nix
#
# Nginx hello-world, fronted by Anubis (TecharoHQ/anubis) — proof-of-work
# reverse proxy that blocks AI/scraper bots. Topology:
#
#   Cilium Ingress (TLS)  →  anubis:8080 (plaintext)  →  nginx:80
#                   host: hello.lab.local
#
# nginx keeps its existing Deployment + ConfigMap; Service type flips
# from NodePort to ClusterIP so scrapers can't bypass Anubis via node
# IPs. Anubis gets a ConfigMap (botPolicies), Deployment, and Service.
# A dedicated nginx-tls Certificate covers hello.lab.local (phase-1
# self-signed; phase-2 flips issuerRef to letsencrypt-prod-dns01).
#
# Secrets (Anubis ED25519 signing key) live outside git — see
# `nix run .#k8s-anubis-bootstrap-secrets`.
#
{ pkgs, lib }:
let
  constants = import ../../constants.nix;
  n = constants.nginx;
  a = constants.anubis;

  # Pre-build LE domain YAML snippets to avoid Nix string indentation issues
  leTlsHosts = lib.concatMapStringsSep "\n    " (d: "- ${d}") n.leDomains;
  leDnsNames = lib.concatMapStringsSep "\n  " (d: "- ${d}") n.leDomains;
  leIngressRules = lib.concatMapStringsSep "\n  " (d: ''
- host: ${d}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: anubis
            port: { number: ${toString a.port} }'') n.leDomains;
in
{
  manifests = [
    {
      name = "nginx/configmap.yaml";
      content = ''
        apiVersion: v1
        kind: ConfigMap
        metadata:
          name: nginx-config
          namespace: nginx
        data:
          index.html: |
            <!DOCTYPE html>
            <html>
            <head><title>K8s MicroVM Cluster</title></head>
            <body>
              <h1>Hello from K8s MicroVM Cluster!</h1>
              <p>This page is served by nginx running on a NixOS MicroVM Kubernetes cluster.</p>
            </body>
            </html>
      '';
    }
    {
      name = "nginx/deployment.yaml";
      content = ''
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: nginx
          namespace: nginx
        spec:
          replicas: 1
          selector:
            matchLabels:
              app: nginx
          template:
            metadata:
              labels:
                app: nginx
            spec:
              containers:
              - name: nginx
                image: nginx:1.27-alpine
                ports:
                - containerPort: 80
                volumeMounts:
                - name: config
                  mountPath: /usr/share/nginx/html/index.html
                  subPath: index.html
                resources:
                  requests:
                    cpu: 50m
                    memory: 32Mi
              volumes:
              - name: config
                configMap:
                  name: nginx-config
      '';
    }
    {
      name = "nginx/service.yaml";
      content = ''
        apiVersion: v1
        kind: Service
        metadata:
          name: nginx
          namespace: nginx
        spec:
          selector:
            app: nginx
          ports:
          - port: 80
            targetPort: 80
          type: ClusterIP
      '';
    }

    # ─── Anubis bot-policy ConfigMap ────────────────────────────────
    # Minimal upstream-style policy: allow well-known mainstream
    # browsers, challenge everything else with PoW. Operator-tuned
    # once real traffic lands — not load-bearing here.
    {
      name = "nginx/anubis-configmap.yaml";
      content = ''
        apiVersion: v1
        kind: ConfigMap
        metadata:
          name: anubis-config
          namespace: nginx
        data:
          botPolicies.yaml: |
            bots:
              # Allow common healthchecks / monitors through without PoW.
              - name: well-known
                user_agent_regex: ^(curl|kube-probe|Prometheus)/
                action: ALLOW
              # Known scraper bots — block outright.
              - name: ai-scrapers
                user_agent_regex: (GPTBot|ChatGPT-User|CCBot|anthropic-ai|ClaudeBot|Google-Extended|PerplexityBot|Bytespider|Amazonbot)
                action: DENY
              # Mainstream browsers — challenge (proof-of-work).
              - name: mainstream-browsers
                user_agent_regex: Mozilla
                action: CHALLENGE
              # Catch-all — challenge.
              - name: default
                user_agent_regex: .*
                action: CHALLENGE
            dnsbl: false
      '';
    }

    # ─── Anubis Deployment ──────────────────────────────────────────
    # Stateless reverse proxy. 1 replica is enough for the lab; scale
    # horizontally when traffic warrants (challenges are stateless).
    # TARGET points at the cluster-local nginx Service — plaintext HTTP
    # inside the cluster, TLS terminates at Cilium Ingress upstream.
    {
      name = "nginx/anubis-deployment.yaml";
      content = ''
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: anubis
          namespace: nginx
        spec:
          replicas: 1
          selector:
            matchLabels:
              app: anubis
          template:
            metadata:
              labels:
                app: anubis
            spec:
              containers:
              - name: anubis
                image: ${a.image}
                ports:
                - name: http
                  containerPort: ${toString a.port}
                - name: metrics
                  containerPort: ${toString a.metrics}
                env:
                - name: BIND
                  value: ":${toString a.port}"
                - name: METRICS_BIND
                  value: ":${toString a.metrics}"
                - name: TARGET
                  value: "http://nginx.nginx.svc.cluster.local:80"
                - name: DIFFICULTY
                  value: "${toString a.difficulty}"
                - name: POLICY_FNAME
                  value: "/etc/anubis/botPolicies.yaml"
                - name: COOKIE_SECURE
                  value: "true"
                - name: ED25519_PRIVATE_KEY_HEX
                  valueFrom:
                    secretKeyRef:
                      name: anubis-secrets
                      key: ed25519_private_key_hex
                volumeMounts:
                - name: policy
                  mountPath: /etc/anubis
                resources:
                  requests:
                    cpu: 50m
                    memory: 64Mi
                  limits:
                    cpu: 500m
                    memory: 256Mi
              volumes:
              - name: policy
                configMap:
                  name: anubis-config
      '';
    }
    {
      name = "nginx/anubis-service.yaml";
      content = ''
        apiVersion: v1
        kind: Service
        metadata:
          name: anubis
          namespace: nginx
        spec:
          selector:
            app: anubis
          ports:
          - name: http
            port: ${toString a.port}
            targetPort: ${toString a.port}
          - name: metrics
            port: ${toString a.metrics}
            targetPort: ${toString a.metrics}
          type: ClusterIP
      '';
    }

    # ─── Self-signed TLS (phase 1) ──────────────────────────────────
    # Phase-2 flips issuerRef to letsencrypt-prod-dns01 alongside the
    # matrix-tls Certificate. The Ingress below references this Secret
    # via tls.secretName.
    {
      name = "nginx/certificate.yaml";
      content = ''
        apiVersion: cert-manager.io/v1
        kind: Certificate
        metadata:
          name: nginx-tls
          namespace: nginx
          annotations:
            argocd.argoproj.io/sync-wave: "2"
        spec:
          secretName: nginx-tls
          duration: 2160h   # 90 days
          renewBefore: 720h # 30 days
          privateKey:
            algorithm: ECDSA
            size: 256
          dnsNames:
          - ${n.hostName}
          issuerRef:
            name: selfsigned-lab
            kind: ClusterIssuer
            group: cert-manager.io
      '';
    }

    # ─── Let's Encrypt TLS (seddon.ca, xtcp.io) ──────────────────────
    # DNS-01 via RFC2136 → PowerDNS. Separate from the lab self-signed
    # cert so hello.lab.local keeps working even without internet.
    {
      name = "nginx/certificate-le.yaml";
      content = ''
        apiVersion: cert-manager.io/v1
        kind: Certificate
        metadata:
          name: nginx-le-tls
          namespace: nginx
          annotations:
            argocd.argoproj.io/sync-wave: "3"
        spec:
          secretName: nginx-le-tls
          duration: 2160h
          renewBefore: 720h
          privateKey:
            algorithm: ECDSA
            size: 256
          dnsNames:
          ${leDnsNames}
          issuerRef:
            name: letsencrypt-prod-dns01
            kind: ClusterIssuer
            group: cert-manager.io
      '';
    }

    # ─── Ingress (all domains → anubis → nginx) ───────────────────
    {
      name = "nginx/ingress.yaml";
      content = ''
        apiVersion: networking.k8s.io/v1
        kind: Ingress
        metadata:
          name: nginx
          namespace: nginx
          annotations:
            cert-manager.io/cluster-issuer: selfsigned-lab
            argocd.argoproj.io/sync-wave: "3"
        spec:
          ingressClassName: cilium
          tls:
          - hosts:
            - ${n.hostName}
            secretName: nginx-tls
          - hosts:
            ${leTlsHosts}
            secretName: nginx-le-tls
          rules:
          - host: ${n.hostName}
            http:
              paths:
              - path: /
                pathType: Prefix
                backend:
                  service:
                    name: anubis
                    port: { number: ${toString a.port} }
          ${leIngressRules}
      '';
    }

    {
      name = "nginx/application.yaml";
      content = ''
        apiVersion: argoproj.io/v1alpha1
        kind: Application
        metadata:
          name: nginx
          namespace: argocd
        spec:
          project: default
          source:
            repoURL: ${constants.gitops.repoURL}
            targetRevision: ${constants.gitops.targetRevision}
            path: ${constants.gitops.renderedPath}/nginx
            directory:
              exclude: 'application.yaml'
          destination:
            server: https://kubernetes.default.svc
            namespace: nginx
          syncPolicy:
            automated:
              prune: true
              selfHeal: true
      '';
    }
  ];
}
