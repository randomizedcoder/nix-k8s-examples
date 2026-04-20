# nix/gitops/default.nix
#
# GitOps manifest generator.
# Generates Kubernetes YAML manifests from Nix using nixidy-style patterns.
# Output: nix build .#k8s-manifests -> result/ directory of YAML files
#
# Each manifest entry is one of two shapes:
#   { name = "ns/file.yaml"; content = "..."; }        # inline string
#   { name = "ns/file.yaml"; source  = <path|drv>; }   # file copied from Nix store
#
# The `source` form lets helm-template outputs flow through to rendered/
# without going via a Nix string (which would IFD-load the contents).
#
{ pkgs, lib, nixidy ? null }:
let
  envDir = ./env;
  helm = import ./helm-chart.nix { inherit pkgs lib; };

  # Import all environment modules
  base         = import (envDir + "/base.nix")          { inherit pkgs lib; };
  argocd       = import (envDir + "/argocd.nix")        { inherit pkgs lib helm; };
  cilium       = import (envDir + "/cilium.nix")        { inherit pkgs lib helm; };
  clickhouse   = import (envDir + "/clickhouse.nix")    { inherit pkgs lib; };
  nginx        = import (envDir + "/nginx.nix")         { inherit pkgs lib; };
  tidb         = import (envDir + "/tidb.nix")          { inherit pkgs lib; };
  fdb          = import (envDir + "/foundationdb.nix")  { inherit pkgs lib; };
  postgres     = import (envDir + "/postgres.nix")      { inherit pkgs lib helm; };
  certManager  = import (envDir + "/cert-manager.nix")  { inherit pkgs lib; };
  matrix       = import (envDir + "/matrix.nix")        { inherit pkgs lib; };

  # Combine all manifests
  allManifests = base.manifests ++ argocd.manifests ++ cilium.manifests
    ++ clickhouse.manifests ++ nginx.manifests
    ++ tidb.manifests
    ++ fdb.manifests
    ++ postgres.manifests
    ++ certManager.manifests
    ++ matrix.manifests;

  emitStep = m:
    if m ? source then ''
      mkdir -p "$out/$(dirname "${m.name}")"
      cp "${m.source}" "$out/${m.name}"
      chmod u+w "$out/${m.name}"
    '' else ''
      mkdir -p "$out/$(dirname "${m.name}")"
      cat > "$out/${m.name}" <<'MANIFEST_EOF'
      ${m.content}
      MANIFEST_EOF
    '';

  manifestDerivation = pkgs.runCommand "k8s-manifests" { } ''
    mkdir -p $out
    ${lib.concatMapStringsSep "\n" emitStep allManifests}
    echo "Generated ${toString (builtins.length allManifests)} manifests" > $out/README
  '';
in
{
  packages = {
    k8s-manifests = manifestDerivation;
  };
}
