# nix/constants.nix
#
# Shared constants for K8s MicroVM cluster infrastructure.
# All network params, serial ports, k8s CIDRs, cert config, lifecycle timeouts.
#
# Topology: 3 control planes (cp0, cp1, cp2) + 1 worker (w3)
#
rec {
  # ─── Node Configuration ──────────────────────────────────────────────
  nodeNames = [ "cp0" "cp1" "cp2" "w3" ];

  # ─── Network Configuration ──────────────────────────────────────────
  network = {
    bridge = "k8sbr0";

    # Per-node TAP devices
    taps = {
      cp0 = "k8stap0";
      cp1 = "k8stap1";
      cp2 = "k8stap2";
      w3  = "k8stap3";
    };

    # Host bridge addresses (dual-stack)
    gateway4 = "10.33.33.1";
    gateway6 = "fd33:33:33::1";
    subnet4 = "10.33.33.0/24";
    subnet6 = "fd33:33:33::/64";

    # Per-node IP addresses
    ipv4 = {
      cp0 = "10.33.33.10";
      cp1 = "10.33.33.11";
      cp2 = "10.33.33.12";
      w3  = "10.33.33.13";
    };
    ipv6 = {
      cp0 = "fd33:33:33::10";
      cp1 = "fd33:33:33::11";
      cp2 = "fd33:33:33::12";
      w3  = "fd33:33:33::13";
    };

    # Per-node MAC addresses
    macs = {
      cp0 = "02:00:0a:21:21:10";
      cp1 = "02:00:0a:21:21:11";
      cp2 = "02:00:0a:21:21:12";
      w3  = "02:00:0a:21:21:13";
    };
  };

  # ─── Kubernetes Network CIDRs ──────────────────────────────────────
  k8s = {
    podCidr4 = "10.244.0.0/16";
    podCidr6 = "fd44:44:44::/48";
    serviceCidr4 = "10.96.0.0/12";
    serviceCidr6 = "fd96:96:96::/108";

    # First service IP (kubernetes.default)
    apiServiceIp = "10.96.0.1";

    # API endpoint via host-side load balancer (haproxy on bridge IP)
    apiEndpoint = "https://${network.gateway4}:6443";

    # DNS
    clusterDomain = "cluster.local";
    dnsServiceIp = "10.96.0.10";

    # PKI directory inside VMs
    pkiDir = "/var/lib/kubernetes/pki";

    # Cert output directory on host
    certDir = "./certs";
  };

  # ─── Serial Console Configuration ──────────────────────────────────
  # Each node gets 10 ports starting at base 25500.
  # +0 = serial (ttyS0), +1 = virtio (hvc0), +2-9 = reserved
  console = {
    portBase = 25500;
    serialOffset = 0;
    virtioOffset = 1;

    nodeBlocks = {
      cp0 = 0;    # 25500-25509
      cp1 = 10;   # 25510-25519
      cp2 = 20;   # 25520-25529
      w3  = 30;   # 25530-25539
    };
  };

  # ─── VM Resources ──────────────────────────────────────────────────
  vm = {
    controlPlane = {
      memoryMB = 8191;  # 8GB (avoid exact power-of-2 — QEMU hangs)
      vcpus = 4;
    };
    worker = {
      memoryMB = 6143;  # 6GB (avoid exact power-of-2 — QEMU hangs)
      vcpus = 2;
    };
  };

  # ─── Observability ─────────────────────────────────────────────────
  nodeExporter = {
    port = 9100;
    listenAddress = "0.0.0.0";  # firewall disabled; bridge reachable
  };

  prometheus = {
    port = 9090;
    retentionTime = "15d";
    # Host that runs the Prometheus server (scrapes all nodes).
    host = "cp0";
  };

  grafana = {
    port = 3000;
    adminUser = "admin";
    adminPassword = "admin";  # test cluster — consistent with ssh password "k8s"
    secretKey = "SW2YcwTIb9zpOOhoPsMm";  # test cluster — legacy Grafana default
    # Pinned rfmoz/grafana-dashboards (Node Exporter Full dashboard).
    dashboardsRepo = {
      owner = "rfmoz";
      repo = "grafana-dashboards";
      rev = "fa9f41fa3efed31d5c2de73cd332a340797c0ec7";
      hash = "sha256-phqtDu/oLwqB+R+Dn9WyHyYbNcKR43uIy+F3BrAvwg4=";
    };
  };

  hubble = {
    uiNodePort    = 31234;  # Hubble UI (HTTP)
    relayNodePort = 31245;  # Hubble Relay gRPC (for `hubble` CLI)
    # Metrics ports live on cilium-agent's host network (hostNetwork=true).
    agentMetricsPort    = 9962;
    operatorMetricsPort = 9963;
    hubbleMetricsPort   = 9965;
  };

  # ─── Cilium Ingress + L2 announcements ─────────────────────────────
  # Cilium runs the cluster's only L7 proxy (Envoy). The built-in
  # ingress controller exposes a single LoadBalancer Service
  # (`cilium-ingress` in kube-system) whose IP is pulled from the
  # LoadBalancer IP pool below and advertised to the LAN via L2 ARP.
  # Host /etc/hosts points every matrix/element/hookshot/maubot name
  # at `vip`. Phase-2: swap L2 for BGP, same VIP.
  cilium = {
    ingress = {
      # Single-IP LB pool. Kept to one IP so the cilium-ingress Service
      # assignment is deterministic — host /etc/hosts entries point
      # every Matrix hostname at this IP. Expand the range when a
      # second LB Service is added.
      vip      = "10.33.33.50";
      vipStart = "10.33.33.50";
      vipStop  = "10.33.33.50";
      # VM-side NIC name (cloud-init renames virtio-net to enp0s4 on
      # these guests; verify with `ip -br link` before first apply if
      # you change the VM image).
      nic      = "enp0s4";
    };
  };

  # ─── Helm chart pins (rendered at Nix build time) ──────────────────
  # Update these by running:
  #   nix-prefetch-url --type sha256 <url>
  #   nix hash convert --hash-algo sha256 --to sri <raw>
  helmCharts = {
    cilium = {
      version = "1.19.3";
      url     = "https://helm.cilium.io/cilium-1.19.3.tgz";
      hash    = "sha256-yOBd+eq/kBnmL1ED4fNYFLTxtDkW+IUZ5a5ONsaapCs=";
    };
    argocd = {
      version = "9.5.0";  # appVersion v3.3.6
      url     = "https://github.com/argoproj/argo-helm/releases/download/argo-cd-9.5.0/argo-cd-9.5.0.tgz";
      hash    = "sha256-2u2U/iCgJ3LFh4w2dKSXbaLF2au5oeIDVpkYnCnfjgk=";
    };
    cnpg = {
      version = "0.28.0";  # appVersion v1.29.0
      url     = "https://github.com/cloudnative-pg/charts/releases/download/cloudnative-pg-v0.28.0/cloudnative-pg-0.28.0.tgz";
      hash    = "sha256-gdN4lPNgbfm9kcVRkFP0GnnoM9KKyiUv+zkpTLnLGa4=";
    };
  };

  # ─── Rancher local-path-provisioner (PV backend for CNPG) ──────────
  localPathProvisioner = {
    version = "v0.0.34";
    url  = "https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.34/deploy/local-path-storage.yaml";
    hash = "sha256-+rjW6JM+RPivc5hgP7YxIuTqZJDwr4NUkQjWhkft2ek=";
  };

  # ─── cert-manager (static installer) ───────────────────────────────
  certManager = {
    version = "v1.16.2";
    url  = "https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.yaml";
    hash = "sha256-HVHN7NRC8fX4l4Pp4BabldNyck2iA8x13XpcTlChDOY=";
  };

  # ─── PostgreSQL (CloudNativePG) NodePorts ──────────────────────────
  postgres = {
    nodePortRw = 30500;  # primary: read-write
    nodePortRo = 30501;  # replicas: read-only
  };

  # ─── TiDB NodePort (host-reachable MySQL-protocol endpoint) ────────
  tidb = {
    nodePort = 30400;  # MySQL on 4000 → host :30400
  };

  # ─── ClickHouse NodePorts (host-reachable HTTP + native) ───────────
  clickhouse = {
    nodePortHttp   = 30423;  # HTTP on 8123 → host :30423
    nodePortNative = 30900;  # native on 9000 → host :30900
  };

  # ─── Observability (ClickStack: OTel Collector + HyperDX UI) ───────
  # Design: docs/observability.md. Implementation lands across 4 PRs:
  #   PR 1 (this one): namespace + scaffolding constants.
  #   PR 2: OTel Collector DS + schema-bootstrap Job.
  #   PR 3: hubble-otel DS + Prometheus remoteWrite bridge.
  #   PR 4: ClickStack UI + MongoDB + Ingress + bootstrap script.
  #
  # Helm chart pins and the clickhouseexporter DDL version are left
  # empty here and populated by the PR that first references them,
  # so a `nix build` on PR 1 does not fetch anything new.
  observability = {
    namespace   = "observability";
    udsHostPath = "/var/run/otel";

    collector = {
      otlpGrpcPort = 4317;   # loopback-TCP OTLP/gRPC fallback receiver
      promRwPort   = 9411;   # prometheusremotewrite receiver (HTTP loopback)
      metricsPort  = 8888;   # collector's own /metrics
      nodePort     = 30411;  # cp0 NodePort for Prom → collector remote_write
    };

    clickhouse = {
      database = "otel";
      cluster  = "ch4";          # must match rendered/clickhouse cluster name
      user     = "otel";         # writer used by the collector
      uiUser   = "hyperdx";      # read-only reader used by ClickStack UI
      # TTL in integer days — interpolated into `toIntervalDay(N)` in DDL.
      ttl = {
        logsDays    = 7;
        tracesDays  = 3;
        metricsDays = 30;
        flowsDays   = 2;
      };
    };

    clickstack = {
      host             = "clickstack.lab.local";
      ingressClassName = "cilium";
      # The ClickStack chart is all-in-one: it ships HyperDX + MongoDB
      # + ClickHouse + OTel Collector. We disable the CH + Collector
      # subcharts (our ch4 cluster and DS from PR 2 own those) but
      # keep the chart's MongoDB Deployment with emptyDir in Phase-1.
      # mongoStorageGi is unused in Phase-1 — emptyDir wins — but
      # stays pinned for the Phase-2 PVC sizing decision.
      mongoStorageGi   = 1;
    };

    # Populated in PR 2 (collector) and PR 4 (clickstack).
    helmCharts = {
      # opentelemetry-collector 0.115.0 ships appVersion 0.118.0 — the
      # contrib image tag we actually run. Keep clickhouseExporterVersion
      # below in lockstep with appVersion so the inlined DDL matches the
      # INSERT statements the exporter emits.
      opentelemetryCollector = {
        version = "0.115.0";
        url     = "https://github.com/open-telemetry/opentelemetry-helm-charts/releases/download/opentelemetry-collector-0.115.0/opentelemetry-collector-0.115.0.tgz";
        hash    = "sha256-zOv5DLMHJnYV9bg0teT4onmJ4xBKlLl7p4FLYNIJdMQ=";
      };
      # hyperdxio/helm-charts clickstack-1.1.1 → ships HyperDX UI +
      # MongoDB + (disabled) ClickHouse + (disabled) OTel Collector.
      # appVersion 2.8.0 is the HyperDX image tag that ships with it.
      clickstack = {
        version = "1.1.1";
        url     = "https://github.com/hyperdxio/helm-charts/releases/download/clickstack-1.1.1/clickstack-1.1.1.tgz";
        hash    = "sha256-Yf0SnyGSJbSqKwwDYl05jL4KQXP5qC+h2XactKhYudM=";
      };
    };

    # Pinned version of opentelemetry-collector-contrib whose canonical
    # clickhouseexporter DDL is inlined into the bootstrap Job's
    # ConfigMap. Keep this in lockstep with the chart's appVersion so
    # the schema we create matches the INSERT column lists the
    # collector emits.
    clickhouseExporterVersion = "v0.118.0";

    # hubble-otel image we push into the in-cluster Zot registry.
    # Upstream (cilium/hubble-otel) is archived — we rebuild the binary
    # via `nix build .#hubble-otel-image` from the archived HEAD and
    # push with `nix run .#k8s-registry-push -- <image> hubble-otel:6f5fe85`.
    # Keep this pin in lockstep with `nix/images/hubble-otel.nix`.
    hubbleOtel = {
      rev      = "6f5fe85ee34f22bc7c151c8a44aacb549e522503";
      shortRev = "6f5fe85";
      image    = "registry.lab.local/hubble-otel:6f5fe85";
      # Local Hubble agent gRPC on every node. Cilium's DaemonSet runs
      # on hostNetwork, so localhost:4244 from a hostNetwork pod hits
      # the agent's gRPC listener directly — no Relay hop.
      hubbleAddress = "localhost:4244";
    };
  };

  # ─── Chaos / failover test defaults ────────────────────────────────
  chaos = {
    defaultRounds         = 10;
    defaultIntervalSec    = 60;
    defaultPostRoundWait  = 60;
    defaultWarmupSec      = 15;
    defaultLogDir         = "./chaos-logs";
  };

  # ─── ArgoCD service (NodePort reachable from host) ─────────────────
  argocd = {
    nodePortHttps = 30443;
  };

  # ─── nginx hello-world site (fronted by Anubis) ───────────────────
  nginx = {
    hostName = "hello.lab.local";
  };

  # ─── In-cluster OCI registry (Zot) ────────────────────────────────
  # A lightweight registry hosted inside the cluster so Nix-built
  # images (e.g. hubble-otel from the archived cilium/hubble-otel
  # tree) can be pushed from the dev box and pulled by containerd
  # without going through a public registry.
  #
  # TLS: the registry leaf cert `registry-tls.{crt,key}` is signed at
  # build time by the cluster CA (see nix/certs.nix) and baked into
  # every node's PKI dir. containerd is configured via
  # /etc/containerd/certs.d/registry.lab.local/hosts.toml to trust
  # the cluster CA for pulls from this host.
  #
  # Reachability: the Zot Service is a LoadBalancer pinned to a
  # dedicated VIP (separate from cilium-ingress so cilium-ingress
  # stays deterministic at .50). /etc/hosts entries on every node
  # (via networking.extraHosts) map registry.lab.local → VIP.
  registry = {
    namespace = "registry";
    host      = "registry.lab.local";
    # Dedicated LB VIP — its own CiliumLoadBalancerIPPool scoped by
    # serviceSelector so it does not contend with cilium-ingress.
    vip       = "10.33.33.51";
    # Zot listens on 5000 (HTTPS). LoadBalancer fronts it on 443.
    httpsPort = 443;
    zotPort   = 5000;
    # PVC size for the registry blob store (local-path).
    storageGi = 5;
    # Zot image pin. Use upstream minimal tag.
    image = "ghcr.io/project-zot/zot-linux-amd64:v2.1.2";
    # Push user for the bootstrap + push scripts; password is
    # generated by `nix run .#k8s-registry-bootstrap-secrets` and
    # stored in the `registry-htpasswd` Secret.
    pushUser = "pusher";
  };

  # ─── Anubis anti-scraper (TecharoHQ/anubis) ───────────────────────
  # Proof-of-work reverse proxy sitting between Cilium Ingress (TLS)
  # and the nginx backend (plaintext ClusterIP). Ingress routes
  # hello.lab.local → anubis:8080 → nginx:80. ED25519 signing key
  # lives in the `anubis-secrets` Secret (bootstrapped out-of-band by
  # `nix run .#k8s-anubis-bootstrap-secrets`).
  anubis = {
    image      = "ghcr.io/techarohq/anubis:v1.25.0";
    port       = 8080;   # Anubis HTTP listener (plaintext)
    metrics    = 9090;   # Prometheus scrape endpoint
    difficulty = 4;      # leading-zero bits for PoW challenge
  };

  # ─── Matrix homeserver + Element + bridges + bots ─────────────────
  #
  # IMPORTANT: Matrix bakes `serverName` into every signed event. It
  # can NOT be changed later without rebuilding the Synapse DB
  # (fresh user accounts, fresh rooms). See docs/matrix.md for the
  # phase-1 → phase-2 public cutover procedure.
  matrix = {
    serverName = "matrix.lab.local";

    # Phase 1 (lab): federation OFF — homeserver answers client API only.
    # Phase 2 (public): flip to true and re-render after public DNS + LE
    # certs are in place. Expect a fresh-DB cutover.
    federation = false;

    # Public hostnames surfaced by the Ingress. All point to the same
    # IP in /etc/hosts for phase-1 lab testing.
    elementHost  = "element.lab.local";
    hookshotHost = "hookshot.lab.local";
    maubotHost   = "maubot.lab.local";

    # Docker image pins (updated manually; matrix upstream tags).
    images = {
      synapse         = "matrixdotorg/synapse:v1.119.0";
      element         = "vectorim/element-web:v1.11.84";
      hookshot        = "halfshot/matrix-hookshot:6.0.3";
      maubot          = "dock.mau.dev/maubot/maubot:v0.5.0";
      mautrixDiscord  = "dock.mau.dev/mautrix/discord:v0.7.2";
    };

    # Synapse media store — single-replica PVC on worker w3 via
    # local-path. Same node-local-storage limitation as CNPG; documented
    # as a phase-2 migration to S3 in docs/resilience-testing.md.
    mediaStorageGi = 5;

    # NodePort for Synapse admin API (host-reachable for one-shot
    # `register_new_matrix_user` from the dev box).
    synapseAdminNodePort = 30800;
  };

  # ─── SSH Configuration ─────────────────────────────────────────────
  ssh = {
    password = "k8s";
    user = "root";
  };

  # ─── Lifecycle Test Configuration ──────────────────────────────────
  lifecycle = {
    pollInterval = 1;

    timeouts = {
      build = 900;
      processStart = 5;
      serialReady = 30;
      virtioReady = 45;
      sshReady = 90;
      certInject = 30;
      serviceReady = 90;
      k8sHealth = 90;
      shutdown = 30;
      waitExit = 60;
    };

    # Cluster-level test timeouts
    clusterTimeouts = {
      nodesReady = 180;
      ciliumReady = 120;
      workloadsReady = 120;
    };
  };

  # ─── GitOps Configuration ────────────────────────────────────────────
  gitops = {
    repoURL = "https://github.com/randomizedcoder/nix-k8s-examples.git";
    targetRevision = "main";
    renderedPath = "rendered";
  };

  # ─── Helper Functions ──────────────────────────────────────────────

  # Get console ports for a node
  getConsolePorts = node: {
    serial = console.portBase + console.nodeBlocks.${node} + console.serialOffset;
    virtio = console.portBase + console.nodeBlocks.${node} + console.virtioOffset;
  };

  # Get hostname for a node
  getHostname = node: "k8s-${node}";

  # Get process name for pgrep matching
  getProcessName = node: getHostname node;

  # Get timeout for a phase (no per-node overrides for now)
  getTimeout = _node: phase: lifecycle.timeouts.${phase};

  # Get all node IPv4 addresses as a list
  allNodeIps4 = builtins.map (n: network.ipv4.${n}) nodeNames;

  # Get all node IPv6 addresses as a list
  allNodeIps6 = builtins.map (n: network.ipv6.${n}) nodeNames;

  # Get VM resources for a role
  getVmResources = role:
    if role == "control-plane" then vm.controlPlane
    else vm.worker;
}
