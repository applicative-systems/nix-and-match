# Lix on other distros

Installs [Lix](https://lix.systems) on other distros with the
[Lix installer](https://git.lix.systems/lix-project/lix-installer), the way
their users do, then checks that it works. This mirrors
[`nix-on-distros`](../nix-on-distros), with the same steps:

1. **install:** the documented one-liner, unchanged:
   `curl -sSf -L https://install.lix.systems/lix | sh -s -- install`.
   The installer's own self-test must pass, and `nix --version` must be
   `nix (Lix, like Nix) <version>`, the Lix release that the installer
   downloads.
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

```sh
nix build .#checks.x86_64-linux.lix-installer-arch -L
```

`lix-installer-repair-<distro>` runs the installer's repair cases, as in
[`nix-on-distros`](../nix-on-distros/README.md#repairs). lix-installer is a
fork of the same installer, and its own VM tests have the same cases.

```sh
nix build .#checks.x86_64-linux.lix-installer-repair-arch -L
```

## Which installer

The installer that the `lix-installer` flake input builds,
`packages.<system>.lix-installer-static`, with its script `lix-installer.sh`.
Neither cache.nixos.org nor cache.lix.systems has it, so the check builds it.
Since `cli: include git commit in --version output` (c39cc26d00), that
package doesn't build in the sandbox: `git_version!()` needs git and a `.git`
directory. `default.nix` puts the input's revision in its place. It also
skips the package's cargo tests, whose plan compatibility fixtures
(`tests/plan.rs`) no longer parse.
Test another revision, such as a pull request, with:

```sh
nix build .#checks.x86_64-linux.lix-installer-arch -L \
  --override-input lix-installer git+https://git.lix.systems/lix-project/lix-installer?ref=<branch>
```

The installer has no Lix inside. It downloads the release tarball whose URL
it was built with, from `releases.lix.systems`. `default.nix` reads that URL
from the installer's `src/distribution.rs` and pins the tarball's hash per
Lix version. When the installer moves to a new Lix release, evaluation stops
and asks for the new hashes:

```sh
nix store prefetch-file https://releases.lix.systems/lix/lix-<version>/lix-<version>-x86_64-linux.tar.xz
```

## How it runs offline

The NixOS node `cache` stands in for the internet:

- nginx answers as `install.lix.systems`, with the script at `/lix` and the
  installer next to it, and as `releases.lix.systems`, with the Lix tarball.
  The certificate is from a test CA that the guest trusts; the installer uses
  the system's roots.
- harmonia serves the node's Nix store as a signed binary cache. The installer
  is told about it with `--extra-conf`.
- sshd lets the guest's root build there, with a key from `keys/`.

`keys/` holds the test CA, the server certificate, the cache's signing key
and the builder's SSH key. They are only for this test network;
`keys/generate.sh` makes new ones.

## Distros

Arch Linux for now, which only runs on x86_64. The other distros of
[`nix-on-distros`](../nix-on-distros/README.md#distros) are one line each in
`default.nix`.
