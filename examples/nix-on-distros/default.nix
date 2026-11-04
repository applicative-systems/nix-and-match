# Nix installed on other distros the way their users install it, then used to
# build something and to run a program from a binary cache. One check per
# distro and install method: nix-<method>-<distro>, and for the NG installer
# its repair cases: nix-ng-installer-repair-<distro>.
{
  pkgs,
  # the NixOS/nix flake, whose Hydra jobs build its installer
  nix,
  # the NixOS/nix-installer flake, the NG installer
  nix-installer,
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
  methods = [
    "installer"
    "ng-installer"
  ];
  # "use": install and use Nix. "repair": install over broken installations,
  # the cases of the NG installer's own tests.
  scenarios = [
    "use"
    "repair"
  ];
  # repairs are what the NG installer promises
  wanted = { method, scenario, ... }: scenario == "use" || method == "ng-installer";
in
lib.listToAttrs (
  map
    (
      args:
      let
        test = pkgs.testers.runNixOSTest {
          imports = [
            testModule
            (import ./test.nix (args // { inherit nix nix-installer; }))
          ];
        };
      in
      lib.nameValuePair test.config.name test
    )
    (
      lib.filter wanted (
        lib.cartesianProduct {
          # guests have the host's system
          distro = lib.filter (d: lib.elem system images.${d}.systems) distros;
          method = methods;
          scenario = scenarios;
        }
      )
    )
)
