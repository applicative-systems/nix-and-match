# Nix on other distros

Installs Nix on other distros the way their users do, then checks that it
works:

1. **install:** the documented one-liner, unchanged:
   `curl -sSfL https://artifacts.nixos.org/nix-installer | sh -s -- install`.
   The installer's own self-test must pass.
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

- nginx answers as `artifacts.nixos.org` and `github.com`, with a certificate
  from a test CA that the guest trusts, and serves the pinned installer. The
  installer binary contains Nix, so nothing else is downloaded.
- harmonia serves the node's Nix store as a signed binary cache. The installer
  is told about it with `--extra-conf`.

`keys/` holds the test CA, the server certificate and the cache's signing key.
They are only for this test network; `keys/generate.sh` makes new ones.

`pins.json` pins the installer. Refresh it with `nix run .#update-examples`.
The hashes come from the release's `SHA256SUMS`, which isn't signed.

## Distros

Debian 13, Ubuntu 24.04, Fedora 44, Arch Linux, AlmaLinux 9, openSUSE
Tumbleweed and Amazon Linux 2023: those in ngipkgs' demo tests, plus
enterprise and SELinux distros. Arch Linux only runs on x86_64.
