{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = inputs: {
    checks = builtins.mapAttrs (
      system: pkgs:
      let
        foreign = import ./lib/foreign-vm.nix { inherit pkgs; };
        images = import ./lib/images.nix { inherit pkgs; };
        mkTest = path: pkgs.testers.runNixOSTest (import path { inherit pkgs foreign images; });
      in
      {
        ubuntu = mkTest ./tests/ubuntu.nix;
        almalinux = mkTest ./tests/almalinux.nix;
        talos = mkTest ./tests/talos.nix;
      }
    ) inputs.nixpkgs.legacyPackages;
  };
}
