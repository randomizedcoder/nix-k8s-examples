# nix/gitops/env/postgres.nix
#
# HA PostgreSQL via CloudNativePG (CNPG) operator.
#
# Layout:
#   - local-path-provisioner (in namespace `local-path-storage`) — dynamic
#     PV backend using node-local hostPath (data is node-local; if a node
#     is destroyed, its replica must re-bootstrap from the primary).
#   - CNPG operator (in namespace `cnpg-system`), Helm-rendered at Nix
#     build time.
#   - PostgreSQL Cluster CR (`pg`, namespace `postgres`): 4 instances
#     spread across cp0/cp1/cp2/w3 via pod anti-affinity. One is primary,
#     the other three are streaming-replication read replicas. CNPG
#     handles promotion on primary failure.
#   - Two NodePort services on the host network so `psql` from the host
#     can reach the rw endpoint (writes) and ro endpoint (reads).
#
# ArgoCD sync-wave annotations order the install:
#   -1: local-path-provisioner + CNPG operator (CRDs appear here)
#    0: Cluster CR (references the CRDs)
#    1: NodePort services (reference the services CNPG creates)
#
{ pkgs, lib, helm }:
let
  constants = import ../../constants.nix;

  # ─── CNPG operator: Helm values ───────────────────────────────────
  operatorValuesYaml = ''
    # CNPG Helm values — rendered at Nix build time.
    # clusterWide: true means the operator watches all namespaces.
    config:
      clusterWide: true
    resources:
      requests:
        cpu: 50m
        memory: 128Mi
  '';

  renderedOperator = helm.renderChart {
    name        = "cnpg";
    releaseName = "cnpg";
    namespace   = "cnpg-system";
    chart       = constants.helmCharts.cnpg;
    values      = operatorValuesYaml;
  };

  # ─── local-path-provisioner: fetched at Nix build time ───────────
  localPathManifest = pkgs.fetchurl {
    url  = constants.localPathProvisioner.url;
    hash = constants.localPathProvisioner.hash;
  };
in
{
  manifests = [
    # ─── local-path-provisioner (PV backend) ────────────────────────
    {
      name = "postgres/local-path-provisioner.yaml";
      source = "${localPathManifest}";
    }

    # ─── CNPG operator (Helm-rendered) ───────────────────────────────
    {
      name = "postgres/operator-install.yaml";
      source = "${renderedOperator}/install.yaml";
    }
    {
      name = "postgres/operator-values.yaml";
      content = operatorValuesYaml;
    }

    # ─── Cluster CR (the PostgreSQL HA cluster itself) ───────────────
    {
      name = "postgres/cluster.yaml";
      content = ''
        apiVersion: postgresql.cnpg.io/v1
        kind: Cluster
        metadata:
          name: pg
          namespace: postgres
          annotations:
            argocd.argoproj.io/sync-wave: "0"
        spec:
          instances: 4
          imageName: ghcr.io/cloudnative-pg/postgresql:16.4
          primaryUpdateStrategy: unsupervised
          storage:
            size: 1Gi
            storageClass: local-path
          affinity:
            podAntiAffinityType: required
            topologyKey: kubernetes.io/hostname
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
          bootstrap:
            initdb:
              database: app
              owner: app
      '';
    }

    # ─── NodePort services for host access ───────────────────────────
    #
    # CNPG creates ClusterIP services `pg-rw` (primary) and `pg-ro`
    # (replicas). Expose them as NodePort so `psql` from the host can
    # connect.
    {
      name = "postgres/service-rw-nodeport.yaml";
      content = ''
        apiVersion: v1
        kind: Service
        metadata:
          name: pg-rw-nodeport
          namespace: postgres
          annotations:
            argocd.argoproj.io/sync-wave: "1"
        spec:
          type: NodePort
          selector:
            cnpg.io/cluster: pg
            cnpg.io/instanceRole: primary
          ports:
          - name: postgres
            port: 5432
            targetPort: 5432
            nodePort: ${toString constants.postgres.nodePortRw}
      '';
    }
    {
      name = "postgres/service-ro-nodeport.yaml";
      content = ''
        apiVersion: v1
        kind: Service
        metadata:
          name: pg-ro-nodeport
          namespace: postgres
          annotations:
            argocd.argoproj.io/sync-wave: "1"
        spec:
          type: NodePort
          selector:
            cnpg.io/cluster: pg
            cnpg.io/instanceRole: replica
          ports:
          - name: postgres
            port: 5432
            targetPort: 5432
            nodePort: ${toString constants.postgres.nodePortRo}
      '';
    }

    # ─── ArgoCD Application ─────────────────────────────────────────
    {
      name = "postgres/application.yaml";
      content = ''
        apiVersion: argoproj.io/v1alpha1
        kind: Application
        metadata:
          name: postgres
          namespace: argocd
        spec:
          project: default
          source:
            repoURL: ${constants.gitops.repoURL}
            targetRevision: ${constants.gitops.targetRevision}
            path: ${constants.gitops.renderedPath}/postgres
            directory:
              recurse: false
              exclude: '{application.yaml,operator-values.yaml}'
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
