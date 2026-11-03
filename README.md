# nix-and-match

NixOS VM tests where non-NixOS machines run alongside NixOS nodes and talk
to them over the test network.

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
nix build .#checks.x86_64-linux.debian-13 -L   # one check per image
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

## Images

`lib/images.json` is generated. Refresh it from the repository root with:

```sh
nix run .#update-images                 # all images
nix run .#update-images -- debian-13    # selected images
```

The updater reads upstream checksum files, so images aren't downloaded except
for Talos. Each pin records its `verification`:

- `signature`: the checksum file is signed by a key in `keys/`.
- `checksum-only`: upstream has no signature, so the hash was read over HTTPS.
- `none`: upstream has no checksum, so the hash comes from a download.

To add a distro, add an `update_<name>` function to
`scripts/update-images.sh` and list it in `all`. Its check is then generated
from `tests/cloud-init.nix`.
