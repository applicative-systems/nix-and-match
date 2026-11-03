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
    ubuntu.succeed("curl -sf http://server/")
  '';
}
```

Run the bundled tests with:

```sh
nix build .#checks.x86_64-linux.debian-13 -L      # one check per image
nix build .#checks.x86_64-linux.provisioners -L   # all provisioners at once
```

The same checks exist for `aarch64-linux` hosts, without Arch Linux.

## How

- Each entry in `foreignNodes` boots a pinned cloud image on a copy-on-write
  overlay, attached to the test's VDE switch with a static IP from a
  cloud-init seed. It is also an empty entry in `nodes` that is never built,
  so the test framework assigns its addresses and hosts entries, available as
  `nodes.<name>.networking.primaryIPAddress`.
- For cloud-init distros, the seed installs the test driver's `hvc0` root
  shell, so `machine.succeed(...)` works as it does on NixOS.
- Talos has no shell. It gets a machine config through `userData` and is
  driven through `talosctl` from a NixOS node.

## Provisioners

`foreignNodes.<name>.provisioner` decides how a machine is set up at first
boot. The image's catalog entry picks the default, so it rarely needs setting.

| Provisioner  | Use it when                                              | Shell |
| ------------ | -------------------------------------------------------- | ----- |
| `cloud-init` | you need some setup in the guest (the default)           | yes   |
| `custom`     | you want to test an existing user-data file, or a script | yes   |
| `none`       | the image has no cloud-init, like Talos                  | no    |

```nix
foreignNodes = {
  # generated cloud-config, plus your settings. Lists are appended.
  web = {
    image = "debian-13";
    cloudInit.config = {
      write_files = [ { path = "/etc/myapp.conf"; content = "server = http://server/"; } ];
      runcmd = [ "systemctl restart myapp" ];
    };
  };

  # your user-data file unchanged; the network setup and shell are added as a
  # second part, which cloud-init merges into it
  prod = {
    image = "ubuntu-24.04";
    provisioner = "custom";
    userData = ./user-data.yaml;
  };

  # no cloud-init: userData is the whole seed, here a Talos machine config
  talos = {
    image = "talos-1.14";
    userData = "${talosConfig}/controlplane.yaml";
  };
};
```

The shell starts only once cloud-init is done, so the first `succeed` waits
for provisioning and the test script needs no `cloud-init status --wait`.
`cloud-init status --long` in the guest shows whether everything worked.

Set `shell = false` to see a cloud-init machine only from the network, as
other hosts would. The test script must then not run commands on it: they wait
for the shell forever. The same applies to `none`.

There is no internet in the test, so `packages` only works with packages that
are already in the image.

`tests/provisioners.nix` uses every combination.

## Architectures

Images are pinned for `x86_64-linux` and `aarch64-linux`, except Arch Linux,
which only publishes x86_64 images. Guests always have the host's system and
run with KVM, so tests for aarch64 guests run on aarch64 hosts. There is no
emulation of other architectures.

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
`scripts/update-images.sh` and list it in `all`. It is called once per system
in `$system`, and `systems_of` lists the systems if it isn't published for all
of them. Its check is then generated
from `tests/cloud-init.nix`. For an image without cloud-init, call
`PROVISIONER=none pin ...` and write its own test, like `tests/talos.nix`.

## License

MIT, see [LICENSE](LICENSE).
