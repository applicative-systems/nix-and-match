{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    inputs:
    let
      inherit (inputs.nixpkgs) lib;
    in
    {
      testModules.default = ./lib/module.nix;

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
          mkTest =
            path:
            pkgs.testers.runNixOSTest {
              imports = [
                inputs.self.testModules.default
                path
              ];
            };
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
