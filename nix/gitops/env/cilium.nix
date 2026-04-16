# nix/gitops/env/cilium.nix
#
# Cilium — rendered-manifests pattern.
#
# At Nix build time: `helm template` is run against the pinned Cilium chart
# tarball with the values below. The result is written to
# rendered/cilium/install.yaml as plain YAML (CRDs included).
# ArgoCD reads that directory via a path-source Application — no in-cluster
# Helm templating.
#
# For the first-boot bootstrap, `install.yaml` is also applied directly by
# the gitops-bootstrap systemd unit on cp0 (since we need Cilium up before
# ArgoCD can sync anything).
#
{ pkgs, lib, helm }:
let
  constants = import ../../constants.nix;

  valuesYaml = ''
    # Cilium Helm values — rendered at Nix build time.
    kubeProxyReplacement: true
    k8sServiceHost: "${constants.network.gateway4}"
    k8sServicePort: "6443"

    ipam:
      mode: kubernetes

    ipv4:
      enabled: true
    ipv6:
      enabled: true

    # ─── Hubble: flow visibility, UI, metrics ───────────────────────
    hubble:
      enabled: true
      # Test env — mTLS disabled so `hubble` CLI from host just works.
      tls:
        enabled: false
      peerService:
        enabled: true
      relay:
        enabled: true
        startupProbe:
          failureThreshold: 40
        service:
          type: NodePort
          nodePort: ${toString constants.hubble.relayNodePort}
      ui:
        enabled: true
        service:
          type: NodePort
          nodePort: ${toString constants.hubble.uiNodePort}
      metrics:
        enableOpenMetrics: true
        enabled:
          - dns
          - drop
          - tcp
          - flow
          - port-distribution
          - icmp
          - "httpV2:exemplars=true;labelsContext=source_ip,source_namespace,source_workload,destination_ip,destination_namespace,destination_workload,traffic_direction"

    # ─── Expose cilium-agent + operator Prometheus endpoints ────────
    prometheus:
      enabled: true
      port: ${toString constants.hubble.agentMetricsPort}

    operator:
      replicas: 1
      prometheus:
        enabled: true
        port: ${toString constants.hubble.operatorMetricsPort}
      resources:
        requests:
          cpu: 50m
          memory: 128Mi

    resources:
      requests:
        cpu: 100m
        memory: 256Mi
  '';

  rendered = helm.renderChart {
    name        = "cilium";
    releaseName = "cilium";
    namespace   = "kube-system";
    chart       = constants.helmCharts.cilium;
    values      = valuesYaml;
  };
in
{
  manifests = [
    # Fully-rendered multi-doc YAML from `helm template`.
    {
      name = "cilium/install.yaml";
      source = "${rendered}/install.yaml";
    }
    # Audit copy of the values used at render time.
    {
      name = "cilium/values.yaml";
      content = valuesYaml;
    }
    # Path-source Application — ArgoCD applies install.yaml and ignores the
    # Application CR file itself (directory.exclude).
    {
      name = "cilium/application.yaml";
      content = ''
        apiVersion: argoproj.io/v1alpha1
        kind: Application
        metadata:
          name: cilium
          namespace: argocd
        spec:
          project: default
          source:
            repoURL: ${constants.gitops.repoURL}
            targetRevision: ${constants.gitops.targetRevision}
            path: ${constants.gitops.renderedPath}/cilium
            directory:
              recurse: false
              exclude: '{application.yaml,values.yaml}'
          destination:
            server: https://kubernetes.default.svc
            namespace: kube-system
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
