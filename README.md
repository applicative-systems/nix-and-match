# nix-and-match

NixOS VM tests where non-NixOS machines (Ubuntu, AlmaLinux, Talos) run
alongside NixOS nodes and talk to them over the test network.

Useful when a NixOS service has to work with hosts you don't control,
such as clients on other distros or appliances like Talos, and you want
that checked hermetically in `nix flake check`.

```nix
pkgs.testers.runNixOSTest {
  imports = [ inputs.nix-and-match.testModules.default ];
  name = "my-service-interop";

  nodes.server = {
    services.nginx = {
      enable = true;
      virtualHosts.server.locations."/".return = "200 'hello'";
    };
    networking.firewall.allowedTCPPorts = [ 80 ];
  };
  foreignNodes.ubuntu.image = "ubuntu-24.04";

  testScript = ''
    start_all()
    server.wait_for_unit("nginx.service")
    ubuntu.succeed("cloud-init status --wait")
    ubuntu.succeed("curl -sf http://server/")
  '';
}
```

Run the bundled tests with:

```sh
nix build .#checks.x86_64-linux.ubuntu -L   # or almalinux, talos
```

## How

- Each entry in `foreignNodes` boots a pinned cloud image on a copy-on-write
  overlay, attached to the test's VDE switch with a static IP from a
  cloud-init seed. It is also an empty entry in `nodes` that is never built,
  so the test framework assigns its addresses and hosts entries, available as
  `nodes.<name>.networking.primaryIPAddress`.
- For cloud-init distros, the seed installs the test driver's `hvc0` root
  shell, so `machine.succeed(...)` works as it does on NixOS.
- Talos has no shell. It gets a machine config through `userDataFile` and is
  driven through `talosctl` from a NixOS node.

To add a distro, pin its image in `lib/images.nix` and copy a test from `tests/`.
