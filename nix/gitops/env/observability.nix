# nix/gitops/env/observability.nix
#
# Observability stack (ClickStack): unified logs, traces, metrics, and
# Hubble flow telemetry → ClickHouse (existing ch4 cluster, new `otel`
# database) → ClickStack UI (HyperDX). Design: docs/observability.md.
#
# This file grows across four PRs:
#   PR 1 (this commit): ArgoCD Application scaffold — namespace comes
#                       from base.nix, no workloads yet.
#   PR 2: OTel Collector DaemonSet + schema-bootstrap Job.
#   PR 3: hubble-otel DaemonSet + Prometheus remoteWrite bridge.
#   PR 4: ClickStack UI + MongoDB + Ingress + bootstrap-secrets script.
#
{ pkgs, lib }:
let
  constants = import ../../constants.nix;
  o = constants.observability;
in
{
  manifests = [
    {
      name = "observability/application.yaml";
      content = ''
        apiVersion: argoproj.io/v1alpha1
        kind: Application
        metadata:
          name: observability
          namespace: argocd
        spec:
          project: default
          source:
            repoURL: ${constants.gitops.repoURL}
            targetRevision: ${constants.gitops.targetRevision}
            path: ${constants.gitops.renderedPath}/observability
            directory:
              exclude: 'application.yaml'
          destination:
            server: https://kubernetes.default.svc
            namespace: ${o.namespace}
          syncPolicy:
            automated:
              prune: true
              selfHeal: true
      '';
    }
  ];
}
