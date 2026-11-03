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

      apps = builtins.mapAttrs (_: pkgs: {
        update-images = {
          type = "app";
          program = lib.getExe (
            pkgs.writeShellApplication {
              name = "update-images";
              runtimeInputs = with pkgs; [
                coreutils
                curl
                gawk
                gnugrep
                gnupg
                gnused
                jq
                nix
                openssl
                xz
              ];
              text = builtins.readFile ./scripts/update-images.sh;
            }
          );
        };
      }) inputs.nixpkgs.legacyPackages;

      checks = builtins.mapAttrs (
        system: pkgs:
        let
          images = lib.attrNames (import ./lib/images.nix { inherit pkgs; });
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
        }
        # images are only pinned for x86_64 so far
        // lib.optionalAttrs (system == "x86_64-linux") (
          lib.genAttrs (lib.remove "talos-1.14" images) (image: mkTest (import ./tests/cloud-init.nix image))
          // {
            "talos-1.14" = mkTest ./tests/talos.nix;
          }
        )
      ) inputs.nixpkgs.legacyPackages;
    };
}
