# Nix on other distros

Installs Nix on other distros the way their users do, with two installers,
then checks that it works:

1. **install:** the documented one-liner, unchanged:
   `curl -sSfL https://artifacts.nixos.org/nix-installer | sh -s -- install`.
   The installer's own self-test must pass, and `nix --version` must be the
   Nix from the flake input.
2. **layout:** there are build users, `/nix/store` is `1775 root:nixbld`, and
   `nix-store --verify --check-contents` passes.
3. **build:** an ordinary user builds a derivation in the sandbox.
4. **remote build:** root builds on the NixOS node over `ssh-ng://`.
5. **binary cache:** the same ordinary user installs mitmproxy from a binary
   cache with `nix-env`, and runs it from `PATH` in a new login shell.
6. **reboot:** after a reboot, the daemon still builds and the program still
   runs.
7. **SELinux:** the logs have no denials involving Nix.
8. **uninstall:** `/nix/nix-installer uninstall` removes everything:
   `/nix`, the build users and group, the daemon's units, and every mention
   of Nix in `/etc`.

There is one check per distro and install method, `nix-<method>-<distro>`:

```sh
nix build .#checks.x86_64-linux.nix-installer-fedora-44 -L
```

## How it runs offline

The NixOS node `cache` stands in for the internet:

- nginx answers as `artifacts.nixos.org` and as the host the installer comes
  from, `releases.nixos.org` or `github.com`, with a certificate from a test
  CA that the guest trusts. The installer binary contains Nix, so nothing else
  is downloaded.
- harmonia serves the node's Nix store as a signed binary cache. The installer
  is told about it with `--extra-conf`.

- sshd lets the guest's root build there, with a key from `keys/`.

`keys/` holds the test CA, the server certificate, the cache's signing key
and the builder's SSH key.
They are only for this test network; `keys/generate.sh` makes new ones.

## Which installers

Both come from flake inputs, and both contain the Nix they install. Their
scripts are served unchanged, at the location they download the installer
binary from.

| Check                       | Installer                                   | Input                                         |
| --------------------------- | ------------------------------------------- | --------------------------------------------- |
| `nix-installer-<distro>`    | Nix's own, as on `releases.nixos.org`       | `nix`: `NixOS/nix` master                     |
| `nix-ng-installer-<distro>` | the NG installer, as on its GitHub releases | `nix-installer`: `NixOS/nix-installer` 2.35.4 |

- **Nix's own installer** tests what comes next: on master, the installer is
  part of Nix. `hydraJobs.nixInstaller.<system>` and
  `hydraJobs.nixInstallerScript` are on cache.nixos.org, since the input has
  no `follows`. Update it with `nix flake update nix`.
- **The NG installer** tests what `curl ... | sh` installs today, with the
  release's own files: the binary is `hydraJobs.build.<system>`, the Hydra
  build that the release copies, from cache.nixos.org, and the script gets its
  version filled in as the release script does. Both match the release's
  `SHA256SUMS`. To test a newer release, change the tag in `flake.nix`.

## Distros

Sixteen, with each distro's supported releases:

| Family     | Releases                                     | SELinux    |
| ---------- | -------------------------------------------- | ---------- |
| Debian     | 12, 13                                       |            |
| Ubuntu     | 22.04, 24.04, 26.04                          |            |
| Fedora     | 43, 44                                       | enforcing  |
| Arch Linux | rolling                                      |            |
| Enterprise | AlmaLinux 9, 10, Rocky 9, 10, Oracle Linux 9 | enforcing  |
| openSUSE   | Leap 16.0, Tumbleweed                        | enforcing  |
| Amazon     | Amazon Linux 2023                            | permissive |

Oracle Linux runs its own kernel, which has no virtiofs; the test doesn't
need it. Arch Linux only runs on x86_64. Each check logs the SELinux mode it
saw.
