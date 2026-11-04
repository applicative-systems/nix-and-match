# Nix installed on other distros the way their users install it, then used to
# build something and to run a program from a binary cache: one check per
# distro, nix-installer-<distro>. The installer's repair cases, installing over
# broken installations, are nix-installer-repair-<distro>.
{
  pkgs,
  # the NixOS/nix flake, whose Hydra jobs build its installer
  nix,
  testModule,
}:
let
  inherit (pkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;
  images = import ../../lib/images.nix { inherit pkgs; };

  distros = [
    "debian-12"
    "debian-13"
    "ubuntu-22.04"
    "ubuntu-24.04"
    "ubuntu-26.04"
    "fedora-43"
    "fedora-44"
    "arch"
    "almalinux-9"
    "almalinux-10"
    "rocky-9"
    "rocky-10"
    "oracle-9"
    "opensuse-leap-16.0"
    "opensuse-tumbleweed"
    "amazon-2023"
  ];
  # "use": install and use Nix. "repair": install over broken installations,
  # the cases of the NG installer's own tests.
  scenarios = [
    "use"
    "repair"
  ];
in
lib.listToAttrs (
  map
    (
      args:
      let
        test = pkgs.testers.runNixOSTest {
          imports = [
            testModule
            (import ./test.nix (args // { inherit nix; }))
          ];
        };
      in
      lib.nameValuePair test.config.name test
    )
    (
      lib.cartesianProduct {
        # guests have the host's system
        distro = lib.filter (d: lib.elem system images.${d}.systems) distros;
        scenario = scenarios;
      }
    )
)
