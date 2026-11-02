{
  config,
  options,
  lib,
  hostPkgs,
  ...
}:
let
  foreign = import ./foreign-vm.nix { pkgs = hostPkgs; };
  catalog = import ./images.nix { pkgs = hostPkgs; };

  mkStartScript =
    name: node:
    let
      inherit (config.nodes.${name}) networking;
    in
    foreign.mkForeignVM (
      {
        inherit name;
        inherit (catalog.${node.image}) image format;
        ip = networking.primaryIPAddress;
        ip6 = networking.primaryIPv6Address;
      }
      // (
        if node.userDataFile != null then
          { inherit (node) userDataFile; }
        else
          { userData = foreign.backdoorCloudConfig { hosts = networking.extraHosts; }; }
      )
    );
in
{
  options.foreignNodes = lib.mkOption {
    description = "Non-NixOS machines that join the test network next to `nodes`.";
    default = { };
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          image = lib.mkOption {
            description = "Image to boot, from `lib/images.nix`.";
            type = lib.types.enum (lib.attrNames catalog);
          };

          userDataFile = lib.mkOption {
            description = ''
              Replaces the generated cloud-config, for images that are not driven
              through a shell. The machine then can't be used with `succeed` and co.
            '';
            type = lib.types.nullOr lib.types.path;
            default = null;
          };
        };
      }
    );
  };

  config = {
    assertions = lib.mapAttrsToList (name: _: {
      assertion = lib.count (def: def.value ? ${name}) options.nodes.definitionsWithLocations == 1;
      message = "`${name}` is defined in both `nodes` and `foreignNodes`";
    }) config.foreignNodes;

    # Each foreign VM is also a node that is evaluated but never built: the test
    # framework then assigns its addresses and vlan and adds it to all hosts files.
    nodes = lib.mapAttrs (_: _: { }) config.foreignNodes;

    driverConfiguration.vms = lib.mapAttrs (name: node: {
      start_script = lib.mkForce (toString (mkStartScript name node));
    }) config.foreignNodes;
  };
}
