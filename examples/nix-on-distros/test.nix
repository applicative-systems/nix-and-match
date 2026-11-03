{
  distro,
  method,
  nix,
  nix-installer,
}:
{
  config,
  hostPkgs,
  lib,
  ...
}:
let
  pkgs = hostPkgs;
  inherit (pkgs.stdenv.hostPlatform) system;
  cacheIp = config.nodes.cache.networking.primaryIPAddress;

  # Where the installer's script downloads the installer binary from, and the
  # Nix that the binary contains and installs. The script is served unchanged.
  installer =
    {
      # Nix's own installer, from the `nix` input, as on releases.nixos.org
      installer =
        let
          package = nix.hydraJobs.nixInstaller.${system};
          version = lib.removePrefix "nix-installer-" package.name;
        in
        {
          nixVersion = version;
          host = "releases.nixos.org";
          path = "/nix/nix-${version}";
          script = "${nix.hydraJobs.nixInstallerScript}/nix-installer";
          binary = lib.getExe package;
        };
      # The NG installer, NixOS/nix-installer, as on its GitHub releases: the
      # binary is the Hydra build that the release copies, so it comes from
      # cache.nixos.org. The script gets its version as the release script
      # does; both are the release's files byte for byte.
      ng-installer =
        let
          package = nix-installer.hydraJobs.build.${system};
          version = lib.removePrefix "nix-installer-" package.name;
        in
        {
          # it contains the Nix of its own `nix` input
          nixVersion = nix-installer.inputs.nix.packages.${system}.nix.version;
          host = "github.com";
          path = "/NixOS/nix-installer/releases/download/${version}";
          script = pkgs.runCommand "nix-installer-${version}.sh" { } ''
            substitute ${nix-installer}/nix-installer.sh $out \
              --replace-fail '$assemble_installer_templated_version' ${version}
          '';
          binary = "${package}/bin/nix-installer";
        };
    }
    .${method};

  # what the cache serves at the installer's download location
  releaseFiles = pkgs.linkFarm "${method}-release" [
    {
      name = "nix-installer.sh";
      path = installer.script;
    }
    {
      name = "nix-installer-${system}";
      path = installer.binary;
    }
  ];

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
  # the documented one-liner, unchanged, for both installers
  installCommand = lib.concatStringsSep " " [
    "curl -sSfL https://artifacts.nixos.org/nix-installer | sh -s -- install --no-confirm"
    "--extra-conf 'substituters = http://cache:5000'"
    "--extra-conf 'trusted-public-keys = ${publicKey}'"
  ];
in
{
  name = "nix-${method}-${distro}";

  nodes.cache = {
    networking.firewall.allowedTCPPorts = [
      443
      5000
    ];

    # stands in for artifacts.nixos.org and where the installer comes from
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
              "302 https://${installer.host}${installer.path}/nix-installer.sh";
          };
          ${installer.host} = tls // {
            locations."${installer.path}/".alias = "${releaseFiles}/";
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
          content = "${cacheIp} artifacts.nixos.org ${installer.host}\n";
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
        # the Nix in the installer from the flake input
        installed = user("nix --version").strip()
        assert installed == "nix (Nix) ${installer.nixVersion}", f"installed {installed}"

    with subtest("an ordinary user builds in the sandbox"):
        out = user("nix-build --no-out-link /etc/nix-demo/build.nix").strip()
        guest.succeed(f"grep -x 'built in the sandbox' {out}")

    with subtest("an ordinary user runs a program from the binary cache"):
        user("nix-store --realise ${demo}")
        guest.log(user("${lib.getExe demo} --version"))

    with subtest("uninstall"):
        guest.log(guest.succeed("/nix/nix-installer uninstall --no-confirm 2>&1"))
        guest.succeed("test ! -e /nix")
        guest.fail("su - alice -c 'command -v nix'")
  '';
}
