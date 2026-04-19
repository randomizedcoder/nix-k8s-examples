# nix/gitops/env/cert-manager.nix
#
# cert-manager — issues TLS certs for Ingress resources.
#
# Two ClusterIssuers ship here:
#
#   1. `selfsigned-lab`   — in-cluster CA. Phase-1 lab use: Element Web
#      and Synapse get certs that browsers will warn on (one-time cert
#      trust); federation is OFF so Matrix.org-side cert validation is
#      not exercised.
#
#   2. `letsencrypt-prod-dns01` — stub, commented out until phase-2 public
#      cutover. DNS-01 is the only sane challenge under anycast (HTTP-01
#      would randomly land on a node that isn't the one cert-manager is
#      running on). The operator will add a secret with DNS provider
#      credentials and uncomment the ClusterIssuer before first use.
#
# Upstream cert-manager.yaml is applied verbatim — we don't patch it. It
# contains the CRDs, operator Deployment, webhook, cainjector, and RBAC.
#
{ pkgs, lib }:
let
  constants = import ../../constants.nix;

  upstreamManifest = pkgs.fetchurl {
    url  = constants.certManager.url;
    hash = constants.certManager.hash;
  };
in
{
  manifests = [
    {
      name = "cert-manager/upstream.yaml";
      source = "${upstreamManifest}";
    }

    # ClusterIssuers — rely on the CRDs in upstream.yaml. Sync-wave 1 so
    # the CRD lands before these.
    {
      name = "cert-manager/issuers.yaml";
      content = ''
        ---
        # ── Phase 1: lab self-signed ───────────────────────────────────
        # A bootstrap "selfsigned" issuer lets us sign a root cert that
        # becomes the in-cluster CA. Ingress resources then reference
        # `selfsigned-lab` as their cluster-issuer.
        apiVersion: cert-manager.io/v1
        kind: ClusterIssuer
        metadata:
          name: selfsigned-bootstrap
          annotations:
            argocd.argoproj.io/sync-wave: "1"
        spec:
          selfSigned: {}
        ---
        apiVersion: cert-manager.io/v1
        kind: Certificate
        metadata:
          name: selfsigned-lab-ca
          namespace: cert-manager
          annotations:
            argocd.argoproj.io/sync-wave: "2"
        spec:
          isCA: true
          commonName: selfsigned-lab-ca
          secretName: selfsigned-lab-ca-cert
          duration: 87600h0m0s   # 10y
          privateKey:
            algorithm: ECDSA
            size: 256
          issuerRef:
            name: selfsigned-bootstrap
            kind: ClusterIssuer
            group: cert-manager.io
        ---
        apiVersion: cert-manager.io/v1
        kind: ClusterIssuer
        metadata:
          name: selfsigned-lab
          annotations:
            argocd.argoproj.io/sync-wave: "3"
        spec:
          ca:
            secretName: selfsigned-lab-ca-cert
        ---
        # ── Phase 2: Let's Encrypt DNS-01 (stub) ───────────────────────
        # Before enabling: create a Secret `acme-dns-provider-credentials`
        # in namespace `cert-manager` with your DNS API token. Then
        # uncomment this block, re-render, and commit. Point the Matrix
        # Ingress `cert-manager.io/cluster-issuer` annotation at
        # `letsencrypt-prod-dns01` instead of `selfsigned-lab`.
        #
        # apiVersion: cert-manager.io/v1
        # kind: ClusterIssuer
        # metadata:
        #   name: letsencrypt-prod-dns01
        # spec:
        #   acme:
        #     server: https://acme-v02.api.letsencrypt.org/directory
        #     email: ops@example.org
        #     privateKeySecretRef:
        #       name: letsencrypt-prod-dns01-account-key
        #     solvers:
        #     - dns01:
        #         cloudflare:
        #           apiTokenSecretRef:
        #             name: acme-dns-provider-credentials
        #             key: api-token
      '';
    }

    {
      name = "cert-manager/application.yaml";
      content = ''
        apiVersion: argoproj.io/v1alpha1
        kind: Application
        metadata:
          name: cert-manager
          namespace: argocd
        spec:
          project: default
          source:
            repoURL: ${constants.gitops.repoURL}
            targetRevision: ${constants.gitops.targetRevision}
            path: ${constants.gitops.renderedPath}/cert-manager
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
