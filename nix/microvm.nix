# nix/microvm.nix
#
# Parametric MicroVM generator for K8s cluster nodes.
# Creates a MicroVM runner for a given node (cp0, w1, w2, w3).
#
# Certs are generated at Nix build time and baked into the VM image
# via activation scripts (copied from /nix/store to /var/lib/kubernetes/pki/).
#
# Returns microvm.declaredRunner - a script that starts the VM.
#
{
  pkgs,
  lib,
  microvm,
  k8sModule,
  monitoringModule,
  bootstrapModule,
  nixpkgs,
  system,
  nodeName,       # "cp0", "w1", "w2", "w3"
  role,           # "control-plane" or "worker"
  nodePki,        # Per-node PKI bundle (from certs.mkNodePki)
  k8sManifests,   # Rendered k8s manifests derivation
  k8sSecrets ? null,       # Pre-generated Secret manifests (from secrets.nix; null if absent)
  sshPubKey ? null,        # SSH ED25519 public key for authorized_keys (from secrets.nix; null if absent)
  hubbleOtelImage ? null,  # hubble-otel docker-archive tarball (from images/hubble-otel.nix)
}:
let
  constants = import ./constants.nix;

  hostname = constants.getHostname nodeName;
  consolePorts = constants.getConsolePorts nodeName;
  resources = constants.getVmResources role;

  nodeIp4 = constants.network.ipv4.${nodeName};
  nodeIp6 = constants.network.ipv6.${nodeName};
  mac = constants.network.macs.${nodeName};
  tap = constants.network.taps.${nodeName};

  pki = constants.k8s.pkiDir;

  vmConfig = nixpkgs.lib.nixosSystem {
    inherit system;

    modules = [
      microvm.nixosModules.microvm
      k8sModule
      monitoringModule
      bootstrapModule

      ({ config, pkgs, ... }: {
        system.stateVersion = "26.05";
        nixpkgs.hostPlatform = system;

        microvm = {
          hypervisor = "qemu";
          mem = resources.memoryMB;
          vcpu = resources.vcpus;

          shares = [{
            tag = "ro-store";
            source = "/nix/store";
            mountPoint = "/nix/.ro-store";
            proto = "9p";
          }];

          volumes = [{
            image = "${hostname}-data.img";
            mountPoint = "/var/lib";
            size = 20480;  # 20GB writable volume for containerd, etcd, kubelet
          }];

          interfaces = [{
            type = "tap";
            id = tap;
            mac = mac;
          }];

          qemu = {
            serialConsole = false;
            extraArgs = [
              "-name" "${hostname},process=${hostname}"
              "-serial" "tcp:127.0.0.1:${toString consolePorts.serial},server,nowait"
              "-device" "virtio-serial-pci"
              "-chardev" "socket,id=virtcon,port=${toString consolePorts.virtio},host=127.0.0.1,server=on,wait=off"
              "-device" "virtconsole,chardev=virtcon"
            ];
          };
        };

        boot.kernelParams = [
          "console=ttyS0,115200"
          "console=hvc0"
        ];

        networking.hostName = hostname;

        # Static dual-stack IP via systemd-networkd
        systemd.network = {
          enable = true;
          networks."10-tap" = {
            matchConfig.Name = "enp*";
            networkConfig = {
              Address = [ "${nodeIp4}/24" "${nodeIp6}/64" ];
              Gateway = constants.network.gateway4;
              DHCP = "no";
              IPv6AcceptRA = false;
            };
            routes = [
              { Gateway = constants.network.gateway4; }
            ];
          };
        };
        networking.useDHCP = false;

        # SSH: key-based auth (preferred) + password fallback for testing
        services.openssh = {
          enable = true;
          settings = {
            PasswordAuthentication = lib.mkForce true;
            PermitRootLogin = lib.mkForce "yes";
            KbdInteractiveAuthentication = lib.mkForce true;
          };
        };
        users.users.root = {
          password = constants.ssh.password;
          openssh.authorizedKeys.keys =
            lib.optional (sshPubKey != null) sshPubKey;
        };

        # ─── PKI: copy build-time certs to /var/lib/kubernetes/pki/ ────
        # Certs are in /nix/store (read-only). Copy to writable PKI dir at boot.
        system.activationScripts.k8s-pki = ''
          mkdir -p ${pki}
          cp -f ${nodePki}/* ${pki}/
          chmod 600 ${pki}/*.key 2>/dev/null || true
          chmod 644 ${pki}/*.crt ${pki}/*.pub 2>/dev/null || true
          chmod 600 ${pki}/*-kubeconfig 2>/dev/null || true
          chmod 644 ${pki}/kubelet-config.yaml 2>/dev/null || true
        '';

        # K8s services
        services.k8s = {
          enable = true;
          inherit role;
          inherit nodeName;
          nodeIp4 = nodeIp4;
          nodeIp6 = nodeIp6;
        };

        # Prometheus + Grafana only on the designated monitoring host.
        services.k8s-monitoring.enable = (nodeName == constants.prometheus.host);

        # First-boot GitOps bootstrap only on cp0.
        services.k8s-gitops-bootstrap = {
          enable = (nodeName == "cp0");
          manifestsPath = k8sManifests;
          secretsPath = k8sSecrets;
        };
      })

      # ─── Registry push service (cp0 only) ───────────────────────────
      # After bootstrap completes, push the Nix-built hubble-otel image
      # into the in-cluster Zot registry. The image tarball is in
      # /nix/store (available via the 9p read-only mount).
      (lib.mkIf (nodeName == "cp0" && hubbleOtelImage != null) {
        systemd.services.k8s-registry-push = {
          description = "Push hubble-otel image to in-cluster registry";

          wants = [ "k8s-gitops-bootstrap.service" ];
          after = [ "k8s-gitops-bootstrap.service" ];
          wantedBy = [ "multi-user.target" ];

          unitConfig = {
            ConditionPathExists = "!/var/lib/k8s-bootstrap/registry-push-done";
          };

          path = with pkgs; [ skopeo curl coreutils kubectl gnugrep ];

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            TimeoutStartSec = "15min";
            Restart = "on-failure";
            RestartSec = "30s";
          };

          script = let
            kubeconfig' = "${constants.k8s.pkiDir}/admin-kubeconfig";
            registryHost = constants.registry.host;
            imageRef = "hubble-otel:${constants.observability.hubbleOtel.shortRev}";
          in ''
            set -eu
            export KUBECONFIG=${kubeconfig'}

            log() { echo "[registry-push] $*"; }

            # Wait for the registry pod to be ready.
            log "waiting for registry at https://${registryHost}/v2/"
            for i in $(seq 1 120); do
              if curl -sk --max-time 3 "https://${registryHost}/v2/" >/dev/null 2>&1; then
                log "  registry is ready"
                break
              fi
              if [ "$i" = "120" ]; then
                log "ERROR: registry not ready after 10min"
                exit 1
              fi
              sleep 5
            done

            # Read push credentials from the registry-htpasswd Secret.
            PUSH_PASS=$(kubectl -n ${constants.registry.namespace} get secret registry-htpasswd \
              -o jsonpath='{.data.htpasswd}' 2>/dev/null | base64 -d || true)
            if [ -z "$PUSH_PASS" ] || echo "$PUSH_PASS" | grep -q "__BOOTSTRAPPED_OUT_OF_BAND__"; then
              log "ERROR: registry-htpasswd Secret not yet populated"
              exit 1
            fi

            # Extract just the password from the htpasswd line (user:$2y$...)
            # For skopeo auth we need user:password, not user:bcrypt.
            # The raw password is in the otel... no, it's in the registry
            # htpasswd. We can't reverse bcrypt, so we read the raw
            # password that nix/secrets.nix also stored. Actually, we
            # need to stash the raw password somewhere the push can read.
            #
            # Simpler approach: store the raw push password in a second
            # key in the registry-htpasswd Secret. nix/secrets.nix adds it.
            RAW_PASS=$(kubectl -n ${constants.registry.namespace} get secret registry-htpasswd \
              -o jsonpath='{.data.push-password}' 2>/dev/null | base64 -d || true)
            if [ -z "$RAW_PASS" ]; then
              log "ERROR: registry-htpasswd Secret missing push-password key"
              exit 1
            fi

            log "pushing ${hubbleOtelImage} → ${registryHost}/${imageRef}"
            skopeo --insecure-policy copy \
              --dest-creds="${constants.registry.pushUser}:$RAW_PASS" \
              --dest-tls-verify=false \
              "docker-archive:${hubbleOtelImage}" \
              "docker://${registryHost}/${imageRef}"

            mkdir -p /var/lib/k8s-bootstrap
            touch /var/lib/k8s-bootstrap/registry-push-done
            log "push complete"
          '';
        };
      })
    ];
  };
in
vmConfig.config.microvm.declaredRunner
