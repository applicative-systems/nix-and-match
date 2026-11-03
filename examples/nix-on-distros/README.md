# Nix on other distros

Installs Nix on other distros the way their users do, then checks that it
works:

1. **install:** the documented one-liner, unchanged:
   `curl -sSfL https://artifacts.nixos.org/nix-installer | sh -s -- install`.
   The installer's own self-test must pass, and `nix --version` must be the
   Nix from the flake input.
2. **build:** an ordinary user builds a derivation in the sandbox.
3. **binary cache:** the same user fetches mitmproxy from a binary cache and
   runs it, as with a project's demo.
4. **uninstall:** `/nix/nix-installer uninstall` removes everything.

There is one check per distro and install method, `nix-<method>-<distro>`:

```sh
nix build .#checks.x86_64-linux.nix-installer-fedora-44 -L
```

## How it runs offline

The NixOS node `cache` stands in for the internet:

- nginx answers as `artifacts.nixos.org` and `releases.nixos.org`, with a
  certificate from a test CA that the guest trusts, and serves the installer.
  The installer binary contains Nix, so nothing else is downloaded.
- harmonia serves the node's Nix store as a signed binary cache. The installer
  is told about it with `--extra-conf`.

`keys/` holds the test CA, the server certificate and the cache's signing key.
They are only for this test network; `keys/generate.sh` makes new ones.

## Which Nix

The installer and its script come from the `nix` flake input, `NixOS/nix`
master: `hydraJobs.nixInstaller.<system>` and `hydraJobs.nixInstallerScript`,
as Hydra builds them for `releases.nixos.org`, so they are on
cache.nixos.org. The input has no `follows`, which would mean building Nix.
Update it with `nix flake update nix`.

This tests the installer before it is released. Nix 2.35 and older were
installed with the separate `NixOS/nix-installer`; to test a release, point
the input at a release branch that has these jobs.

## Distros

Debian 13, Ubuntu 24.04, Fedora 44, Arch Linux, AlmaLinux 9, openSUSE
Tumbleweed and Amazon Linux 2023: those in ngipkgs' demo tests, plus
enterprise and SELinux distros. Arch Linux only runs on x86_64.
