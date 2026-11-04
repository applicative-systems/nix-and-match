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

  # built in the sandbox, with nothing to substitute: by an ordinary user, on
  # each boot, or on the NixOS node as a remote builder
  build = ''
    { where ? "first-boot" }:
    derivation {
      name = "built-on-${distro}-''${where}";
      system = builtins.currentSystem;
      builder = "/bin/sh";
      args = [ "-c" "echo built in the sandbox > $out" ];
    }
  '';

  publicKey = lib.fileContents ./keys/cache.public;
  ca = builtins.readFile ./keys/ca.pem;
  # where the CA goes where cloud-init's ca_certs doesn't work: it doesn't
  # support Arch, and Rocky 9's cloud-init skips it as "not verified on rocky"
  caAnchors = {
    arch = "/etc/ca-certificates/trust-source/anchors";
    rocky-9 = "/etc/pki/ca-trust/source/anchors";
  };
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
    # the guest's remote builder
    services.openssh.enable = true;
    users.users.root.openssh.authorizedKeys.keyFiles = [ ./keys/builder.pub ];

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
        {
          path = "/root/.ssh/builder";
          permissions = "0600";
          content = builtins.readFile ./keys/builder;
        }
        {
          path = "/root/.ssh/config";
          content = ''
            Host cache
              IdentityFile /root/.ssh/builder
              StrictHostKeyChecking no
              UserKnownHostsFile /dev/null
          '';
        }
      ]
      ++ lib.optional (caAnchors ? ${distro}) {
        path = "${caAnchors.${distro}}/nix-and-match.crt";
        content = ca;
      };
      runcmd = [
        "useradd --create-home --shell /bin/bash alice"
      ]
      ++ lib.optional (caAnchors ? ${distro}) "update-ca-trust";
    }
    # trust the test CA
    // lib.optionalAttrs (!caAnchors ? ${distro}) { ca_certs.trusted = [ ca ]; };
  };

  testScript = ''
    start_all()
    cache.wait_for_unit("nginx.service")
    cache.wait_for_unit("harmonia.socket")

    # in a new login shell of an ordinary user, as after logging in
    def user(command):
        return guest.succeed(f"su - alice -c '{command}'")

    # root's login shell: the test's shell started before Nix was installed
    def root(command):
        return guest.succeed(f"bash -lc '{command}'")

    def build(where):
        out = user(f"nix-build --no-out-link --argstr where {where} /etc/nix-demo/build.nix").strip()
        guest.succeed(f"grep -x 'built in the sandbox' {out}")

    guest.log(guest.succeed("grep PRETTY_NAME /etc/os-release"))
    guest.log("SELinux: " + guest.succeed("getenforce 2>/dev/null || echo not present"))

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

    with subtest("the store belongs to root and the build users"):
        gid = guest.succeed("getent group nixbld | cut -d: -f3").strip()
        builders = guest.succeed(f"getent passwd | awk -F: '$4 == {gid}' | cut -d: -f1").split()
        assert builders, "no build users"
        guest.log(f"{len(builders)} build users")
        guest.succeed("test \"$(stat -c '%a %U %G' /nix/store)\" = '1775 root nixbld'")
        root("nix-store --verify --check-contents")

    with subtest("an ordinary user builds in the sandbox"):
        build("first-boot")

    with subtest("root builds on the NixOS node"):
        cache.wait_for_unit("sshd.service")
        out = root(
            "nix-build --no-out-link --max-jobs 0 --builders ssh-ng://root@cache"
            " --argstr where cache /etc/nix-demo/build.nix"
        ).strip()
        cache.succeed(f"grep -x 'built in the sandbox' {out}")
        guest.succeed(f"grep -x 'built in the sandbox' {out}")

    with subtest("an ordinary user installs a program from the binary cache"):
        user("nix-env --install ${demo}")
        # on PATH in a new login shell
        guest.log(user("${demo.meta.mainProgram} --version"))

    with subtest("nix works after a reboot"):
        guest.shutdown()
        guest.start()
        build("second-boot")
        guest.log(user("${demo.meta.mainProgram} --version"))

    with subtest("no SELinux denials for nix"):
        denials = guest.succeed(
            "{ cat /var/log/audit/audit.log 2>/dev/null; journalctl -k --no-pager 2>/dev/null; }"
            " | grep 'avc: *denied' | grep nix | grep -v nixos-test-backdoor || true"
        )
        assert denials == "", denials

    with subtest("uninstall"):
        guest.log(guest.succeed("/nix/nix-installer uninstall --no-confirm 2>&1"))
        guest.succeed("test ! -e /nix")
        guest.fail("su - alice -c 'command -v nix'")
        guest.fail("getent group nixbld")
        guest.fail(f"getent passwd | awk -F: '$4 == {gid}' | grep .")
        guest.fail("systemctl cat nix-daemon.service")
        guest.fail("systemctl cat nix-daemon.socket")
        # nothing in /etc points to Nix any more: shell profiles, configs, units
        leftovers = guest.succeed("grep -rlsI -e /nix/var -e nix-daemon /etc || true")
        assert leftovers == "", f"left in /etc: {leftovers}"
  '';
}
