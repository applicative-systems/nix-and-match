{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    inputs:
    let
      inherit (inputs.nixpkgs) lib;
    in
    {
      formatter = builtins.mapAttrs (
        _: pkgs:
        pkgs.treefmt.withConfig {
          settings = {
            tree-root-file = "flake.nix";
            on-unmatched = "info";
            formatter = {
              nixfmt = {
                command = lib.getExe pkgs.nixfmt;
                includes = [ "*.nix" ];
              };
              statix = {
                command = lib.getExe pkgs.statix;
                options = [ "fix" ];
                no-positional-arg-support = true;
                includes = [ "*.nix" ];
              };
              deadnix = {
                command = lib.getExe pkgs.deadnix;
                options = [ "--edit" ];
                includes = [ "*.nix" ];
              };
              prettier = {
                command = lib.getExe pkgs.prettier;
                options = [ "--write" ];
                includes = [ "*.md" ];
              };
            };
          };
        }
      ) inputs.nixpkgs.legacyPackages;

      checks = builtins.mapAttrs (
        system: pkgs:
        let
          foreign = import ./lib/foreign-vm.nix { inherit pkgs; };
          images = import ./lib/images.nix { inherit pkgs; };
          mkTest = path: pkgs.testers.runNixOSTest (import path { inherit pkgs foreign images; });
        in
        {
          formatting = inputs.self.formatter.${system}.check inputs.self;

          ubuntu = mkTest ./tests/ubuntu.nix;
          almalinux = mkTest ./tests/almalinux.nix;
          talos = mkTest ./tests/talos.nix;
        }
      ) inputs.nixpkgs.legacyPackages;
    };
}
