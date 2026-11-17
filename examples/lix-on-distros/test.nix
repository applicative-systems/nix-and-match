{
  distro,
  # "use": install, then use Lix as people do. "repair": the installer's
  # repair cases, installing over broken installations.
  scenario,
  # the installer under test and the Lix release it installs, see default.nix
  installer,
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
  tarballPath = lib.removePrefix "https://releases.lix.systems" installer.tarballUrl;

  # a program from the binary cache, like a project's demo
  demo = pkgs.mitmproxy;
  # a small one, substituted after every repair
  small = pkgs.hello;

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
  # the documented one-liner, unchanged
  installCommand = lib.concatStringsSep " " [
    "curl -sSf -L https://install.lix.systems/lix | sh -s -- install --no-confirm"
    "--extra-conf 'substituters = http://cache:5000'"
    "--extra-conf 'trusted-public-keys = ${publicKey}'"
  ];

  # helpers for both scenarios
  prelude = ''
    start_all()
    cache.wait_for_unit("nginx.service")
    cache.wait_for_unit("harmonia.socket")

    # in a new login shell of an ordinary user, as after logging in
    def user(command):
        return guest.succeed(f"su - alice -c '{command}'")

    # root's login shell: the test's shell started before Lix was installed
    def root(command):
        return guest.succeed(f"bash -lc '{command}'")

    def build(where):
        out = user(f"nix-build --no-out-link --argstr where {where} /etc/nix-demo/build.nix").strip()
        guest.succeed(f"grep -x 'built in the sandbox' {out}")

    def install():
        # to a pipe: with the serial console as stdout, the installer fails silently
        output = guest.succeed("${installCommand} 2>&1")
        guest.log(output)
        # the installer only warns when nix isn't usable from a new shell
        assert "SelfTest" not in output, "the installer's self-test failed"

    # what a working installation looks like
    def assert_installed():
        guest.succeed("systemctl is-enabled nix-daemon.socket")
        guest.succeed("systemctl is-active nix-daemon.socket")
        # the Lix release that the installer downloads
        # (then Lix describes its build: system types, features, paths)
        installed = user("nix --version").splitlines()[0]
        assert installed == "nix (Lix, like Nix) ${installer.lixVersion}", f"installed {installed}"
        guest.succeed("getent group nixbld")
        guest.succeed("getent passwd | grep -E '^nixbld[0-9]+:'")
        guest.succeed("test \"$(stat -c '%a %U %G' /nix/store)\" = '1775 root nixbld'")
        # every store object canonical: owned by root, mtime 1
        odd = guest.succeed(
            "find /nix/store -mindepth 1 ! -path '/nix/store/.links*' -printf '%T@ %u:%g %p\\n'"
            " | awk '$1 + 0 != 1 || $2 != \"root:root\"' > /tmp/odd; head -n 5 /tmp/odd"
        )
        assert odd == "", f"store objects not canonical: {odd}"

    # what a clean system looks like
    def assert_uninstalled():
        guest.succeed("test ! -e /nix")
        guest.fail("su - alice -c 'command -v nix'")
        guest.fail("getent group nixbld")
        guest.fail("getent passwd | grep -E '^nixbld[0-9]+:'")
        guest.fail("systemctl cat nix-daemon.service")
        guest.fail("systemctl cat nix-daemon.socket")
        # nothing in /etc points to Lix any more: shell profiles, configs, units
        leftovers = guest.succeed("grep -rlsI -e /nix/var -e nix-daemon /etc || true")
        assert leftovers == "", f"left in /etc: {leftovers}"

    def uninstall():
        guest.log(guest.succeed("/nix/nix-installer uninstall --no-confirm 2>&1"))
        assert_uninstalled()

    guest.log(guest.succeed("grep PRETTY_NAME /etc/os-release"))
    guest.log("SELinux: " + guest.succeed("getenforce 2>/dev/null || echo not present"))

    with subtest("the test CA and hosts are in place"):
        guest.succeed("curl -sSfI https://install.lix.systems/lix")
        guest.succeed("curl -sSfI ${installer.tarballUrl}")

  '';

  scripts.use = ''
    with subtest("install"):
        install()
        assert_installed()
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

    with subtest("lix works after a reboot"):
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
        uninstall()
  '';

  # The cure-self and uninstall cases of the installer's own VM tests
  # (nix/tests/vm-test), in one machine: each starts and ends with a clean
  # system.
  scripts.repair = ''
    remove_build_users = "getent passwd | grep -E '^nixbld[0-9]+:' | cut -d: -f1 | xargs -n 1 userdel"

    # install, lose the receipt, break something, then install over it
    cure_self = {
        # case: (how it breaks, what shows that it is broken)
        "working": ("true", "true"),
        "no-nix": ("rm -rf /nix", "test ! -e /nix"),
        "missing-users": (
            "userdel nixbld1 && userdel nixbld3 && userdel nixbld16",
            "! getent passwd nixbld3",
        ),
        "missing-users-and-group": (
            f"{remove_build_users} && groupdel nixbld",
            "! getent group nixbld",
        ),
        "daemon-disabled": (
            "systemctl disable --now nix-daemon.socket",
            "! systemctl is-enabled nix-daemon.socket",
        ),
        "daemon-stopped": (
            "systemctl stop nix-daemon.socket",
            "! systemctl is-active nix-daemon.socket",
        ),
        "no-etc-nix": ("rm -rf /etc/nix", "test ! -e /etc/nix"),
        # the snippets that put Lix on PATH, wherever this distro has them
        "no-shell-hooks": (
            "grep -rlZ '# End Nix' /etc | xargs -0 -r sed -i '/# Nix/,/# End Nix/d'",
            "! su - alice -c 'command -v nix'",
        ),
    }
    for case, (breaking, broken) in cure_self.items():
        with subtest(f"cure-self: {case}"):
            install()
            guest.succeed("mv /nix/receipt.json /nix/old-receipt.json")
            guest.succeed(breaking)
            guest.succeed(broken)
            install()
            assert_installed()
            build(case)
            user("nix-store --realise ${small}")
            user("${lib.getExe small}")
            uninstall()

    # uninstall a broken installation. The installer's own tests expect the
    # uninstaller to fail here; what matters is that nothing is left.
    uninstall_broken = {
        "missing-users-and-group": f"{remove_build_users} && groupdel nixbld",
        "no-etc-nix": "rm -rf /etc/nix",
    }
    for case, breaking in uninstall_broken.items():
        with subtest(f"uninstall a broken installation: {case}"):
            install()
            guest.succeed(breaking)
            status, output = guest.execute("/nix/nix-installer uninstall --no-confirm 2>&1")
            guest.log(f"uninstaller exited with {status}:\n{output}")
            assert_uninstalled()
  '';
in
{
  name =
    if scenario == "use" then "lix-installer-${distro}" else "lix-installer-${scenario}-${distro}";

  nodes.cache = {
    # the guest's remote builder
    services.openssh.enable = true;
    users.users.root.openssh.authorizedKeys.keyFiles = [ ./keys/builder.pub ];

    networking.firewall.allowedTCPPorts = [
      443
      5000
    ];

    # stands in for install.lix.systems, which serves the script and the
    # installer, and releases.lix.systems, where the installer gets Lix from
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
          "install.lix.systems" = tls // {
            locations."= /lix".alias = installer.script;
            locations."= /lix/lix-installer-${system}".alias = installer.binary;
          };
          "releases.lix.systems" = tls // {
            locations."= ${tarballPath}".alias = installer.tarball;
          };
        };
    };

    # the binary cache
    services.harmonia.cache = {
      enable = true;
      signKeyPaths = [ ./keys/cache.secret ];
    };
    virtualisation.additionalPaths =
      {
        use = [ demo ];
        repair = [ small ];
      }
      .${scenario};
  };

  foreignNodes.guest = {
    image = distro;
    memorySize = 3072;
    cloudInit.config = {
      write_files = [
        {
          path = "/etc/hosts";
          append = true;
          content = "${cacheIp} install.lix.systems releases.lix.systems\n";
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

  testScript = prelude + scripts.${scenario};
}
