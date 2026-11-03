{
  config,
  options,
  lib,
  hostPkgs,
  ...
}:
let
  top = config;
  foreign = import ./foreign-vm.nix { pkgs = hostPkgs; };
  catalog = import ./images.nix { pkgs = hostPkgs; };
  inherit (hostPkgs.stdenv.hostPlatform) system;

  # the same folders as on NixOS test VMs, so the driver's `copy_from_host` and
  # `copy_from_machine` work. Images without virtiofs and Talos get none.
  shares =
    node:
    lib.optionalAttrs (catalog.${node.image}.virtiofs && node.provisioner != "none") {
      xchg = {
        source = ''"$TMPDIR"/xchg'';
        target = "/tmp/xchg";
        writable = true;
      };
      shared = {
        source = ''"''${SHARED_DIR:-$TMPDIR/xchg}"'';
        target = "/tmp/shared";
        writable = true;
      };
    };

  userDataFile =
    name: node:
    let
      inherit (top.nodes.${name}) networking;
      args = {
        inherit name;
        inherit (node) shell;
        shares = shares node;
        hosts = networking.extraHosts;
        ip = networking.primaryIPAddress;
        ip6 = networking.primaryIPv6Address;
      };
    in
    {
      cloud-init = foreign.cloudInitUserData (args // { extraConfig = node.cloudInit.config; });
      custom = foreign.customUserData (args // { inherit (node) userData; });
      none = if node.userData != null then node.userData else hostPkgs.writeText "${name}-user-data" "";
    }
    .${node.provisioner};

  unavailable =
    name: node:
    "foreignNodes.${name}: image ${node.image} is not available for ${system}, only for ${
      lib.concatStringsSep ", " catalog.${node.image}.systems
    }";

  mkStartScript =
    name: node:
    let
      inherit (top.nodes.${name}) networking;
      entry = catalog.${node.image};
    in
    foreign.mkForeignVM {
      inherit name;
      inherit (entry) format;
      inherit (entry.pins.${system} or (throw (unavailable name node))) image;
      inherit (node)
        memorySize
        cores
        diskSize
        ;
      ip = networking.primaryIPAddress;
      ip6 = networking.primaryIPv6Address;
      inherit (top.nodes.${name}.virtualisation.test) nodeNumber;
      shares = shares node;
      userDataFile = userDataFile name node;
    };

  nodeOptions =
    { config, ... }:
    {
      options = {
        image = lib.mkOption {
          description = ''
            Image to boot, from `lib/images.json`. Refresh the pins with
            `nix run .#update-images`.

            The guest has the host's system, so the image must be published
            for it: Arch Linux, for example, is only published for
            `x86_64-linux`. Run tests for other architectures on hosts of that
            architecture.
          '';
          type = lib.types.enum (lib.attrNames catalog);
          example = "debian-13";
        };

        provisioner = lib.mkOption {
          description = ''
            How the machine is set up at first boot. All of them boot the image
            with a static address on the test network and pass a NoCloud seed.

            - `cloud-init`: the module generates the cloud-config. Use this
              unless you have a reason not to: add your own settings with
              `cloudInit.config`, and the test script can use `succeed` and co.
              as soon as cloud-init is done.
            - `custom`: your own user-data file in `userData`, passed to
              cloud-init unchanged, with the generated cloud-config added as a
              second part. Use this to test a user-data file that is also used
              outside of the test, or one that isn't a cloud-config, such as a
              shell script.
            - `none`: `userData` is the whole seed, nothing is added. Use this
              for images without cloud-init, such as Talos. The machine has no
              shell: drive it over the network from a NixOS node.

            The default comes from the image's catalog entry.
          '';
          type = lib.types.enum [
            "cloud-init"
            "custom"
            "none"
          ];
          default = catalog.${config.image}.provisioner;
          defaultText = lib.literalMD "the image's `provisioner` in `lib/images.json`";
          example = "custom";
        };

        cloudInit.config = lib.mkOption {
          description = ''
            Settings added to the generated cloud-config, for
            `provisioner = "cloud-init"`. Lists, such as `packages`, `runcmd`
            and `write_files`, are appended to the generated ones, maps are
            merged and other values replace the generated ones.

            Everything here is done before the shell is available, so the test
            script doesn't need to wait for it. Remember that the test network
            has no internet access: `packages` only works with packages that
            are already in the image.
          '';
          inherit ((hostPkgs.formats.yaml { })) type;
          default = { };
          example = lib.literalExpression ''
            {
              write_files = [
                {
                  path = "/etc/myapp.conf";
                  content = "server = http://server/";
                }
              ];
              runcmd = [ "systemctl enable --now myapp" ];
            }
          '';
        };

        userData = lib.mkOption {
          description = ''
            User-data file for `provisioner = "custom"` or `"none"`.

            With `custom`, it can be anything cloud-init accepts as one part of
            a multipart message, such as a cloud-config or a shell script, but
            not a multipart message itself. Lists in a cloud-config are kept,
            and the generated ones are appended.

            With `none`, it is the seed's whole user-data, such as a Talos
            machine config. Without it, Talos waits in maintenance mode for a
            config to be applied over its API.
          '';
          type = lib.types.nullOr lib.types.path;
          default = null;
          example = lib.literalExpression "./user-data.yaml";
        };

        shell = lib.mkOption {
          description = ''
            Whether the test driver gets a root shell on the machine, so the
            test script can use `succeed`, `wait_for_unit` and co. It starts
            once cloud-init is done. `cloud-init status` on the machine tells
            whether it succeeded.

            Turn it off to test the machine only from the outside, as other
            hosts on a network would see it. The test script must then not call
            any command on the machine besides `start`, `shutdown` and `crash`:
            those wait for the shell forever. Always off with
            `provisioner = "none"`.
          '';
          type = lib.types.bool;
          default = config.provisioner != "none";
          defaultText = lib.literalExpression ''provisioner != "none"'';
          example = false;
        };

        memorySize = lib.mkOption {
          description = "Memory of the machine in MiB.";
          type = lib.types.ints.positive;
          default = 2048;
          example = 4096;
        };

        cores = lib.mkOption {
          description = "Number of CPU cores of the machine.";
          type = lib.types.ints.positive;
          default = 2;
          example = 4;
        };

        diskSize = lib.mkOption {
          description = ''
            Size of the machine's disk, in `qemu-img` syntax: absolute, such as
            `"20G"`, or relative to the image's size, such as `"+5G"`. Disks
            only grow: an absolute size below the image's size keeps the image's
            size. cloud-init grows the root partition and file system on boot,
            images without cloud-init may not use the extra space.

            Use a relative size when the test needs free space whatever the
            image's size is, since images differ: Debian's is 3G, Amazon
            Linux's 25G. The disk is a copy-on-write overlay, so only what the
            test writes takes space on the host.
          '';
          type = lib.types.strMatching "\\+?[0-9]+[KMGT]?";
          default = "10G";
          example = "+5G";
        };
      };
    };

  checks =
    name: node:
    let
      p = node.provisioner;
    in
    [
      {
        assertion = lib.count (def: def.value ? ${name}) options.nodes.definitionsWithLocations == 1;
        message = "`${name}` is defined in both `nodes` and `foreignNodes`";
      }
      {
        assertion = p == "cloud-init" || node.cloudInit.config == { };
        message = "foreignNodes.${name}.cloudInit.config needs provisioner = \"cloud-init\", but it is \"${p}\"; with \"custom\", put the settings into userData";
      }
      {
        assertion = p != "cloud-init" || node.userData == null;
        message = "foreignNodes.${name}.userData needs provisioner = \"custom\" or \"none\"; use cloudInit.config to add settings to the generated cloud-config";
      }
      {
        assertion = p != "custom" || node.userData != null;
        message = "foreignNodes.${name}.userData must be set with provisioner = \"custom\"";
      }
      {
        assertion = p != "none" || !node.shell;
        message = "foreignNodes.${name}.shell is not possible with provisioner = \"none\": nothing installs the shell";
      }
      {
        assertion = lib.elem system catalog.${node.image}.systems;
        message = unavailable name node;
      }
      {
        assertion = p == "none" || catalog.${node.image}.provisioner == "cloud-init";
        message = "foreignNodes.${name}: image ${node.image} has no cloud-init, so provisioner must be \"none\"";
      }
    ];
in
{
  options.foreignNodes = lib.mkOption {
    description = ''
      Non-NixOS machines that join the test network next to `nodes`. Each
      gets an address and hosts entry like a node, and the test script refers
      to it by its name.
    '';
    default = { };
    type = lib.types.attrsOf (lib.types.submodule nodeOptions);
    example = lib.literalExpression ''
      {
        ubuntu.image = "ubuntu-24.04";
        talos = {
          image = "talos-1.14";
          userData = "''${talosConfig}/controlplane.yaml";
        };
      }
    '';
  };

  config = {
    assertions = lib.concatLists (lib.mapAttrsToList checks config.foreignNodes);

    warnings = lib.concatLists (
      lib.mapAttrsToList (
        name: node:
        lib.optional
          (node.provisioner == "none" && node.userData == null && lib.hasPrefix "talos-" node.image)
          "foreignNodes.${name} has no userData, so Talos stays in maintenance mode until a config is applied"
      ) config.foreignNodes
    );

    # Each foreign VM is also a node that is evaluated but never built: the test
    # framework then assigns its addresses and vlan and adds it to all hosts files.
    nodes = lib.mapAttrs (_: _: { }) config.foreignNodes;

    driverConfiguration.vms = lib.mapAttrs (name: node: {
      start_script = lib.mkForce (toString (mkStartScript name node));
    }) config.foreignNodes;
  };
}
