{
  config,
  lib,
  hostPkgs,
  ...
}:
let
  foreign = import ./foreign-vm.nix { pkgs = hostPkgs; };
  catalog = import ./images.nix { pkgs = hostPkgs; };

  vlan = 1;
  foreignNames = lib.attrNames config.foreignNodes;

  nixosVlans = lib.concatMap (
    m: m.virtualisation.vlans ++ lib.mapAttrsToList (_: v: v.vlan) m.virtualisation.interfaces
  ) (lib.attrValues config.nodes ++ lib.attrValues config.containers);

  nixosHosts = lib.concatStrings (
    lib.mapAttrsToList (name: node: "${node.networking.primaryIPAddress} ${name}\n") config.nodes
  );
  foreignHosts = lib.concatStrings (
    lib.mapAttrsToList (name: node: "${node.ip} ${name}\n") config.foreignNodes
  );

  mkStartScript =
    name: node:
    foreign.mkForeignVM (
      {
        inherit name;
        inherit (catalog.${node.image}) image format;
        inherit (node) ip;
      }
      // (
        if node.userDataFile != null then
          { inherit (node) userDataFile; }
        else
          { userData = foreign.backdoorCloudConfig { hosts = nixosHosts + foreignHosts; }; }
      )
    );
in
{
  options.foreignNodes = lib.mkOption {
    description = "Non-NixOS machines that join the test network next to `nodes`.";
    default = { };
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          options = {
            image = lib.mkOption {
              description = "Image to boot, from `lib/images.nix`.";
              type = lib.types.enum (lib.attrNames catalog);
            };

            ip = lib.mkOption {
              description = "Static IP. The default stays clear of the low addresses of NixOS nodes.";
              type = lib.types.str;
              default = "192.168.${toString vlan}.${
                toString (100 + lib.lists.findFirstIndex (n: n == name) 0 foreignNames)
              }";
              defaultText = "192.168.1.100 upwards, in name order";
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
      )
    );
  };

  config = lib.mkIf (config.foreignNodes != { }) {
    assertions = [
      {
        assertion = lib.intersectLists foreignNames (lib.attrNames config.allMachines) == [ ];
        message = "foreignNodes and nodes must not share names";
      }
    ];

    defaults.networking.extraHosts = foreignHosts;

    driverConfiguration = {
      vms = lib.mapAttrs (name: node: {
        inherit name;
        start_script = toString (mkStartScript name node);
      }) config.foreignNodes;

      # not deduplicated upstream: a second vde_switch on the same socket hangs the driver
      vlans = lib.optional (!lib.elem vlan nixosVlans) vlan;
    };
  };
}
