# Nix on other distros

Installs Nix on other distros the way their users do, then checks that it
works:

1. **install:** the documented one-liner, unchanged:
   `curl -sSfL https://artifacts.nixos.org/nix-installer | sh -s -- install`.
   The installer's own self-test must pass, and `nix --version` must be the
   Nix from the flake input.
2. **layout:** there are build users, `/nix/store` is `1775 root:nixbld`,
   everything in it is owned by `root:root` with mtime 1, and
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

There is one check per distro, `nix-installer-<distro>`:

```sh
nix build .#checks.x86_64-linux.nix-installer-fedora-44 -L
```

## Repairs

The installer promises to repair broken installations when it runs again.
`nix-installer-repair-<distro>` runs the cases of the NG installer's own VM
tests, all in one machine. Each case starts from a clean system and ends with
an uninstall that must leave nothing behind, as above.

- **cure-self:** install, lose `/nix/receipt.json`, break the installation,
  check that it is broken, then install again with the one-liner. The result
  must pass the layout checks, build, and substitute from the cache. The
  breakages:
  - none
  - `/nix` deleted
  - three build users deleted
  - all build users and the group deleted
  - the daemon socket disabled
  - the daemon socket stopped
  - `/etc/nix` deleted
  - the snippets that put Nix on `PATH` removed from `/etc`
- **uninstall a broken installation:** delete the build users and group, or
  `/etc/nix`, then uninstall. The uninstaller exits with an error here, as the
  NG installer's tests expect, but it must still remove everything.

```sh
nix build .#checks.x86_64-linux.nix-installer-repair-debian-13 -L
```

## Which installer

The installer that Nix master builds, from the `nix` flake input: the NG
installer, [NixOS/nix-installer](https://github.com/NixOS/nix-installer),
with that Nix inside, and Nix's script. This is where the NG installer is
going: it is being moved into Nix's release process
([NixOS/nix#16134](https://github.com/NixOS/nix/issues/16134)), and its own
repository no longer ships a script.

`hydraJobs.nixInstaller.<system>` and `hydraJobs.nixInstallerScript` are on
cache.nixos.org, since the input has no `follows`. The script is served
unchanged, at the `releases.nixos.org` location it downloads the binary from.
Update it with `nix flake update nix`.

## How it runs offline

The NixOS node `cache` stands in for the internet:

- nginx answers as `artifacts.nixos.org` and `releases.nixos.org`, with a
  certificate from a test CA that the guest trusts. The installer binary
  contains Nix, so nothing else is downloaded.
- harmonia serves the node's Nix store as a signed binary cache. The installer
  is told about it with `--extra-conf`.
- sshd lets the guest's root build there, with a key from `keys/`.

`keys/` holds the test CA, the server certificate, the cache's signing key
and the builder's SSH key. They are only for this test network;
`keys/generate.sh` makes new ones.

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
