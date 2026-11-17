# Lix installed on other distros with the Lix installer, the way their users
# install it, then used to build something and to run a program from a binary
# cache: one check per distro, lix-installer-<distro>. The installer's repair
# cases, installing over broken installations, are
# lix-installer-repair-<distro>.
{
  pkgs,
  # the lix-project/lix-installer flake
  lix-installer,
  testModule,
}:
let
  inherit (pkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;
  images = import ../../lib/images.nix { inherit pkgs; };

  # The installer downloads Lix itself, from the URL it was built with. The
  # cache serves that release tarball, pinned here.
  tarballs = {
    "2.95.1" = {
      x86_64-linux = "sha256-/TvYaa3bJRQ1MHMOvhJA8n33RvR/PqV93JPaa2lAnxU=";
      aarch64-linux = "sha256-RmQXX5ItwQYydPZ7eS/KOjww75SuUE9Ec1TRKFLkSR4=";
    };
  };

  installer =
    let
      # the URL compiled into the installer, from its source
      urls = lib.flatten (
        lib.filter lib.isList (
          builtins.split ''"(https://releases\.lix\.systems/[^"]*-${system}\.tar\.xz)"'' (
            builtins.readFile "${lix-installer}/src/distribution.rs"
          )
        )
      );
      tarballUrl =
        assert lib.assertMsg (lib.length urls == 1) "no Lix tarball URL for ${system} in lix-installer";
        lib.head urls;
      lixVersion = lib.elemAt (builtins.match ".*/lix-([^/]+)-${system}\\.tar\\.xz" tarballUrl) 0;
      # `git_version!()` runs git on the source at compile time, which the
      # flake's package has neither of: put the input's revision there instead.
      # Its plan compatibility tests (tests/plan.rs) fail on their fixtures;
      # this test is about installing, so leave them to the installer's CI.
      package = lix-installer.packages.${system}.lix-installer-static.overrideAttrs (old: {
        doCheck = false;
        postPatch = (old.postPatch or "") + ''
          substituteInPlace src/cli/mod.rs \
            --replace-fail 'git_version!()' '"${lix-installer.rev or lix-installer.dirtyRev or "unknown"}"'
        '';
      });
    in
    assert lib.assertMsg (tarballs ? ${lixVersion}.${system})
      "lix-installer downloads Lix ${lixVersion}; add its tarball's hash for ${system} to examples/lix-on-distros/default.nix";
    {
      inherit lixVersion tarballUrl;
      tarball = pkgs.fetchurl {
        url = tarballUrl;
        hash = tarballs.${lixVersion}.${system};
      };
      script = "${package}/bin/lix-installer.sh";
      binary = "${package}/bin/lix-installer";
    };

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
  # "use": install and use Lix. "repair": install over broken installations,
  # the cases of the NG installer's own tests, which lix-installer shares.
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
            (import ./test.nix (args // { inherit installer; }))
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
