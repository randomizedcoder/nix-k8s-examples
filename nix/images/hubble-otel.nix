# nix/images/hubble-otel.nix
#
# hubble-otel (github.com/cilium/hubble-otel) — archived upstream.
# Fetched at the archive-notice HEAD, built from source with Go 1.26,
# wrapped as an OCI image that gets pushed into the in-cluster Zot
# registry via `nix run .#k8s-registry-push`.
#
# The vendor/ directory is committed upstream, so buildGoModule runs
# with vendorHash = null (no proxy-based dep fetch). If Go 1.26 rejects
# constructs in the frozen (go 1.16) codebase we patch here; keep
# patches small and document why.
#
{ pkgs, lib }:
let
  # Archived HEAD of cilium/hubble-otel (README archive-notice commit,
  # 2024-06-20). The commit immediately before it — 34b5ba9 — is the
  # last code change and is functionally identical; we pin HEAD so the
  # build is reproducible against the literal frozen repo.
  rev = "6f5fe85ee34f22bc7c151c8a44aacb549e522503";
  shortRev = builtins.substring 0 7 rev;

  src = pkgs.fetchFromGitHub {
    owner = "cilium";
    repo  = "hubble-otel";
    inherit rev;
    # hash filled in after first `nix build` run prints the real value.
    hash = "sha256-n/3sJqKd2qaVS/AodRhGuJvKLET6AbestTQBzqk6miQ=";
  };

  bin = pkgs.buildGoModule {
    pname = "hubble-otel";
    version = shortRev;
    inherit src;

    # vendor/ is committed; no module downloads required.
    vendorHash = null;

    # Upstream Dockerfile builds only the top-level main.go
    # (`go build -o /out/usr/bin/hubble-otel ./`). buildGoModule's
    # default behaviour is to walk every subpackage, which trips on
    # `./receiver` being a non-main helper in the module root.
    subPackages = [ "." ];

    # Pinned toolchain per project convention.
    go = pkgs.go_1_26;

    # The frozen repo says `go 1.16` in go.mod. Go 1.26 is stricter
    # about the toolchain line; -mod=vendor + GOTOOLCHAIN=local forces
    # it to build against the committed vendor tree without upgrading
    # the directive.
    env = {
      GOFLAGS = "-mod=vendor";
      GOTOOLCHAIN = "local";
      CGO_ENABLED = "0";
    };

    ldflags = [ "-s" "-w" ];

    # Upstream tests spin up a local Hubble mock and require network
    # access. Skip in the Nix sandbox.
    doCheck = false;

    meta = with lib; {
      description = "Adapter from Hubble flows to OpenTelemetry (archived upstream; rebuilt locally)";
      homepage = "https://github.com/cilium/hubble-otel";
      license = licenses.asl20;
      mainProgram = "hubble-otel";
    };
  };

  # OCI image — pushed into the cluster's Zot at
  #   registry.lab.local/hubble-otel:<shortRev>
  # CA certs are pulled in so hubble-otel can verify TLS if someone
  # ever points it at a remote relay; today the DS talks to the local
  # cilium-agent over UDS and doesn't need them, but the footprint is
  # ~400 KB and leaving them out creates a landmine.
  image = pkgs.dockerTools.buildImage {
    name = "hubble-otel";
    tag  = shortRev;

    copyToRoot = pkgs.buildEnv {
      name = "hubble-otel-root";
      paths = [ bin pkgs.cacert ];
      pathsToLink = [ "/bin" "/etc" ];
    };

    config = {
      Entrypoint = [ "/bin/hubble-otel" ];
      Env = [
        "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
      ];
    };
  };
in
{
  inherit bin image rev shortRev;
}
