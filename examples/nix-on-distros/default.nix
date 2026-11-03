# Nix installed on other distros the way their users install it, then used to
# build something and to run a program from a binary cache. One check per
# distro and install method: nix-<method>-<distro>.
{
  pkgs,
  # the NixOS/nix flake, whose Hydra jobs build the installer
  nix,
  testModule,
}:
let
  inherit (pkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;
  images = import ../../lib/images.nix { inherit pkgs; };

  distros = [
    "debian-13"
    "ubuntu-24.04"
    "fedora-44"
    "arch"
    "almalinux-9"
    "opensuse-tumbleweed"
    "amazon-2023"
  ];
  methods = [ "installer" ];
in
lib.listToAttrs (
  map
    (
      { distro, method }:
      lib.nameValuePair "nix-${method}-${distro}" (
        pkgs.testers.runNixOSTest {
          imports = [
            testModule
            (import ./test.nix { inherit distro method nix; })
          ];
        }
      )
    )
    (
      lib.cartesianProduct {
        # guests have the host's system
        distro = lib.filter (d: lib.elem system images.${d}.systems) distros;
        method = methods;
      }
    )
)
