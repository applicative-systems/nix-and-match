# nix-and-match

NixOS VM tests where non-NixOS machines (Ubuntu, AlmaLinux, Talos) run
alongside NixOS nodes and talk to them over the test network.

Useful when a NixOS service has to work with hosts you don't control,
such as clients on other distros or appliances like Talos, and you want
that checked hermetically in `nix flake check`.

```sh
nix build .#checks.x86_64-linux.ubuntu -L   # or almalinux, talos
```

## How

- `create_machine()` boots a pinned cloud image on a copy-on-write overlay,
  attached to the test's VDE switch with a static IP from a cloud-init seed.
- For cloud-init distros, the seed installs the test driver's `hvc0` root
  shell, so `machine.succeed(...)` works as it does on NixOS.
- Talos has no shell. It gets a machine config at build time and is driven
  through `talosctl` from a NixOS node.

To add a distro, pin its image in `lib/images.nix` and copy a test from `tests/`.
