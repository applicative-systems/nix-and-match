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

`tests/` protects this repository and its images from regressions.
`examples/` tests something useful with it, and shows how:

- [`examples/nix-on-distros`](examples/nix-on-distros): installs Nix on
  sixteen distros with two installers, then builds, builds remotely on a
  NixOS node, runs software from a binary cache, reboots and uninstalls.

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
Machines survive `shutdown()` and `start()`: the disk is kept, and the shell,
the addresses and the shared folders come back on every boot.
`cloud-init status --long` in the guest shows whether everything worked.

Set `shell = false` to see a cloud-init machine only from the network, as
other hosts would. The test script must then not run commands on it: they wait
for the shell forever. The same applies to `none`.

There is no internet in the test, so `packages` only works with packages that
are already in the image.

`tests/provisioners.nix` uses every combination.

## Shared folders

cloud-init machines get the same shared folders as NixOS test VMs, over
virtiofs: `/tmp/xchg` and `/tmp/shared`, which all machines of the test share.
So `copy_from_host` and `copy_from_machine` work as on NixOS. The folders are
mounted before the shell starts. With `provisioner = "cloud-init"`, they are
also mounted before the `runcmd` commands from `cloudInit.config` run.

Add your own with `sharedDirectories`, as on NixOS test VMs:

```nix
foreignNodes.web = {
  image = "debian-13";
  sharedDirectories = {
    # read-only, from the Nix store
    www = { source = "${./www}"; target = "/srv/www"; };
    # writable; $TMPDIR is the machine's state directory on the host
    logs = { source = ''"$TMPDIR"/logs''; target = "/srv/logs"; writable = true; };
  };
};
```

To run programs built with Nix on a machine, list them in `additionalPaths`.
The host's Nix store is then shared read-only at `/nix/store`, so they run
with all their dependencies, also as systemd services and with SELinux:

```nix
foreignNodes.ubuntu = {
  image = "ubuntu-24.04";
  additionalPaths = [ myClient ];
};
# testScript: ubuntu.succeed("${myClient}/bin/my-client http://server/")
```

Oracle Linux's kernel has no virtiofs, so it gets no shared folders: use
`copy_from_host_via_shell` there. Machines with `provisioner = "none"` don't
get them either, and neither can use `additionalPaths`.

## Architectures

Images are pinned for `x86_64-linux` and `aarch64-linux`, except Arch Linux,
which only publishes x86_64 images. Guests always have the host's system and
run with KVM, so tests for aarch64 guests run on aarch64 hosts. There is no
emulation of other architectures.

## Interactive runs

Every test has a `driverInteractive`, as NixOS tests do:

```sh
nix run .#checks.x86_64-linux.debian-13.driverInteractive
```

In the Python prompt, `start_all()` boots the machines, `guest.succeed(...)`
runs commands, and `guest.shell_interact()` opens a root shell on a machine
with a shell. The machines have no root password, so there is no console
login; their consoles only show up in the log. `$QEMU_OPTS` is passed to QEMU
of all machines, foreign ones included.

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
`PROVISIONER=none pin ...` and write its own test, like `tests/talos.nix`. If
the image's kernel has no virtiofs, add `"virtiofs": false` to its entry by
hand; the updater keeps it.

## License

MIT, see [LICENSE](LICENSE).
