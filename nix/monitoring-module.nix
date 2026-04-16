# nix/monitoring-module.nix
#
# NixOS module: Prometheus server + Grafana.
# Enabled only on cp0. Scrapes node_exporter on all 4 cluster nodes.
# Provisions the rfmoz "Node Exporter Full" dashboard pinned by commit+hash.
#
{ config, pkgs, lib, ... }:
with lib;
let
  constants = import ./constants.nix;
  cfg = config.services.k8s-monitoring;

  # Pinned rfmoz/grafana-dashboards — see constants.grafana.dashboardsRepo.
  grafanaDashboardsSrc = pkgs.fetchFromGitHub {
    inherit (constants.grafana.dashboardsRepo) owner repo rev hash;
  };

  # Stage only the dashboards we want provisioned.
  dashboardDir = pkgs.runCommand "grafana-dashboards-selected" { } ''
    mkdir -p $out
    cp ${grafanaDashboardsSrc}/prometheus/node-exporter-full.json $out/
  '';
in
{
  options.services.k8s-monitoring = {
    enable = mkEnableOption "K8s cluster monitoring (Prometheus + Grafana on cp0)";
  };

  config = mkIf cfg.enable {
    # ─── Prometheus server ────────────────────────────────────────────
    services.prometheus = {
      enable = true;
      port = constants.prometheus.port;
      retentionTime = constants.prometheus.retentionTime;
      globalConfig = {
        scrape_interval = "15s";
        evaluation_interval = "15s";
      };
      scrapeConfigs = [
        {
          job_name = "node";
          static_configs = map (n: {
            targets = [ "${constants.network.ipv4.${n}}:${toString constants.nodeExporter.port}" ];
            labels = { instance = n; };
          }) constants.nodeNames;
        }
        {
          job_name = "prometheus";
          static_configs = [{
            targets = [ "localhost:${toString constants.prometheus.port}" ];
            labels = { instance = "cp0"; };
          }];
        }
        # Cilium agents run with hostNetwork=true on every node, so
        # their metrics endpoints are reachable directly on the node IP.
        {
          job_name = "cilium-agent";
          static_configs = map (n: {
            targets = [ "${constants.network.ipv4.${n}}:${toString constants.hubble.agentMetricsPort}" ];
            labels = { instance = n; };
          }) constants.nodeNames;
        }
        {
          job_name = "hubble";
          static_configs = map (n: {
            targets = [ "${constants.network.ipv4.${n}}:${toString constants.hubble.hubbleMetricsPort}" ];
            labels = { instance = n; };
          }) constants.nodeNames;
        }
        {
          # Operator runs on one node — scrape all and tolerate DOWN on 3.
          job_name = "cilium-operator";
          static_configs = map (n: {
            targets = [ "${constants.network.ipv4.${n}}:${toString constants.hubble.operatorMetricsPort}" ];
            labels = { instance = n; };
          }) constants.nodeNames;
        }
      ];
    };

    # ─── Grafana ──────────────────────────────────────────────────────
    services.grafana = {
      enable = true;
      settings = {
        server = {
          http_addr = "0.0.0.0";
          http_port = constants.grafana.port;
          domain = constants.prometheus.host;
        };
        security = {
          admin_user = constants.grafana.adminUser;
          admin_password = constants.grafana.adminPassword;
          # Test cluster — hard-coded secret_key (no sensitive DB contents).
          # In production, use a file-provider: secret_key = "$__file{/run/keys/grafana-secret}".
          secret_key = constants.grafana.secretKey;
        };
        "auth.anonymous" = {
          enabled = true;
          org_role = "Viewer";
        };
        analytics.reporting_enabled = false;
      };
      provision = {
        enable = true;
        datasources.settings = {
          apiVersion = 1;
          datasources = [{
            name = "Prometheus";
            type = "prometheus";
            access = "proxy";
            url = "http://localhost:${toString constants.prometheus.port}";
            isDefault = true;
          }];
        };
        dashboards.settings = {
          apiVersion = 1;
          providers = [{
            name = "default";
            orgId = 1;
            folder = "";
            type = "file";
            disableDeletion = false;
            updateIntervalSeconds = 60;
            allowUiUpdates = false;
            options.path = dashboardDir;
          }];
        };
      };
    };
  };
}
