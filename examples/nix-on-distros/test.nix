{ distro, method }:
{
  config,
  hostPkgs,
  lib,
  ...
}:
let
  pkgs = hostPkgs;
  inherit (pkgs.stdenv.hostPlatform) system;
  pins = lib.importJSON ./pins.json;
  installer = pins.nix-installer;
  cacheIp = config.nodes.cache.networking.primaryIPAddress;

  # what the cache serves as github.com
  installerFiles = pkgs.linkFarm "nix-installer-${installer.version}" (
    map
      (name: {
        inherit name;
        path = pkgs.fetchurl {
          url = "https://github.com/NixOS/nix-installer/releases/download/${installer.version}/${name}";
          hash = installer.hashes.${name};
        };
      })
      [
        "nix-installer.sh"
        "nix-installer-${system}"
      ]
  );

  # a program from the binary cache, like a project's demo
  demo = pkgs.mitmproxy;

  # built by an ordinary user, in the sandbox, with nothing to substitute
  build = ''
    derivation {
      name = "built-on-${distro}";
      system = builtins.currentSystem;
      builder = "/bin/sh";
      args = [ "-c" "echo built in the sandbox > $out" ];
    }
  '';

  publicKey = lib.fileContents ./keys/cache.public;
  ca = builtins.readFile ./keys/ca.pem;
  installCommand =
    {
      # the documented one-liner, unchanged
      installer = lib.concatStringsSep " " [
        "curl -sSfL https://artifacts.nixos.org/nix-installer | sh -s -- install --no-confirm"
        "--extra-conf 'substituters = http://cache:5000'"
        "--extra-conf 'trusted-public-keys = ${publicKey}'"
      ];
    }
    .${method};
in
{
  name = "nix-${method}-${distro}";

  nodes.cache = {
    networking.firewall.allowedTCPPorts = [
      443
      5000
    ];

    # stands in for artifacts.nixos.org and github.com
    services.nginx = {
      enable = true;
      virtualHosts =
        let
          tls = {
            onlySSL = true;
            sslCertificate = ./keys/server.pem;
            sslCertificateKey = ./keys/server.key;
          };
        in
        {
          "artifacts.nixos.org" = tls // {
            locations."= /nix-installer".return =
              "302 https://github.com/NixOS/nix-installer/releases/download/${installer.version}/nix-installer.sh";
          };
          "github.com" = tls // {
            locations."/NixOS/nix-installer/releases/download/${installer.version}/".alias =
              "${installerFiles}/";
          };
        };
    };

    # the binary cache
    services.harmonia.cache = {
      enable = true;
      signKeyPaths = [ ./keys/cache.secret ];
    };
    virtualisation.additionalPaths = [ demo ];
  };

  foreignNodes.guest = {
    image = distro;
    memorySize = 3072;
    cloudInit.config = {
      write_files = [
        {
          path = "/etc/hosts";
          append = true;
          content = "${cacheIp} artifacts.nixos.org github.com\n";
        }
        {
          path = "/etc/nix-demo/build.nix";
          content = build;
        }
      ]
      ++ lib.optional (distro == "arch") {
        path = "/etc/ca-certificates/trust-source/anchors/nix-and-match.crt";
        content = ca;
      };
      runcmd = [
        "useradd --create-home --shell /bin/bash alice"
      ]
      ++ lib.optional (distro == "arch") "update-ca-trust";
    }
    # trust the test CA. cloud-init's ca_certs doesn't support Arch.
    // lib.optionalAttrs (distro != "arch") { ca_certs.trusted = [ ca ]; };
  };

  testScript = ''
    start_all()
    cache.wait_for_unit("nginx.service")
    cache.wait_for_unit("harmonia.socket")

    def user(command):
        return guest.succeed(f"su - alice -c '{command}'")

    with subtest("the test CA and hosts are in place"):
        guest.succeed("curl -sSfI https://artifacts.nixos.org/nix-installer")

    with subtest("install"):
        # to a pipe: with the serial console as stdout, the installer fails silently
        output = guest.succeed("${installCommand} 2>&1")
        guest.log(output)
        # the installer only warns when nix isn't usable from a new shell
        assert "SelfTest" not in output, "the installer's self-test failed"
        guest.succeed("systemctl is-active nix-daemon.socket || systemctl is-active nix-daemon.service")
        guest.log(user("nix --version"))

    with subtest("an ordinary user builds in the sandbox"):
        out = user("nix-build --no-out-link /etc/nix-demo/build.nix").strip()
        guest.succeed(f"grep -x 'built in the sandbox' {out}")

    with subtest("an ordinary user runs a program from the binary cache"):
        user("nix-store --realise ${demo}")
        guest.log(user("${lib.getExe demo} --version"))
  ''
  + lib.optionalString (method == "installer") ''
    with subtest("uninstall"):
        guest.log(guest.succeed("/nix/nix-installer uninstall --no-confirm 2>&1"))
        guest.succeed("test ! -e /nix")
        guest.fail("su - alice -c 'command -v nix'")
  '';
}
