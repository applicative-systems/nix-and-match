{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      foreign = import ./lib/foreign-vm.nix { inherit pkgs; };
      images = import ./lib/images.nix { inherit pkgs; };
      mkTest = path: pkgs.testers.runNixOSTest (import path { inherit pkgs foreign images; });
    in
    {
      checks.${system} = {
        ubuntu = mkTest ./tests/ubuntu.nix;
        almalinux = mkTest ./tests/almalinux.nix;
        talos = mkTest ./tests/talos.nix;
      };
    };
}
