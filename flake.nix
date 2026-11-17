{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  # examples/nix-on-distros
  # no follows for caching.
  inputs.nix.url = "github:NixOS/nix";
  # examples/lix-on-distros
  inputs.lix-installer.url = "git+https://git.lix.systems/lix-project/lix-installer";

  outputs =
    inputs:
    let
      inherit (inputs.nixpkgs) lib;
      # hosts that run foreign nodes, see `machine` in lib/foreign-vm.nix
      foreignSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
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
          meta.description = "Refresh the image pins in lib/images.json";
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
          images = import ./lib/images.nix { inherit pkgs; };
          # each host only tests the images published for its own system
          cloudInitImages = lib.attrNames (
            lib.filterAttrs (_: i: i.provisioner == "cloud-init" && lib.elem system i.systems) images
          );
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
        // lib.optionalAttrs (lib.elem system foreignSystems) (
          lib.genAttrs cloudInitImages (image: mkTest (import ./tests/cloud-init.nix image))
          // {
            "talos-1.14" = mkTest ./tests/talos.nix;
            provisioners = mkTest ./tests/provisioners.nix;
            containers = mkTest ./tests/containers.nix;
            qemu-opts = (mkTest ./tests/qemu-opts.nix).overrideTestDerivation {
              QEMU_OPTS = "-smbios type=1,serial=nix-and-match";
            };
          }
          # examples: tests of something other than this repository
          // import ./examples/nix-on-distros {
            inherit pkgs;
            inherit (inputs) nix;
            testModule = inputs.self.testModules.default;
          }
          // import ./examples/lix-on-distros {
            inherit pkgs;
            inherit (inputs) lix-installer;
            testModule = inputs.self.testModules.default;
          }
        )
      ) inputs.nixpkgs.legacyPackages;
    };
}
