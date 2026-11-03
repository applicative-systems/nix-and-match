{ config, hostPkgs, ... }:
let
  pkgs = hostPkgs;
  images = import ../lib/images.nix { inherit pkgs; };
  ip = config.nodes.talos.networking.primaryIPAddress;
  clientIp = config.nodes.client.networking.primaryIPAddress;

  # no shell on talos: it gets a machine config via nocloud user-data and is driven through its API
  talosConfig = import ./talos-config.nix {
    inherit pkgs ip;
    inherit (images."talos-1.14") version;
    timeServer = clientIp;
  };
in
{
  name = "talos-interop";

  foreignNodes.talos = {
    image = "talos-1.14";
    userData = "${talosConfig}/controlplane.yaml";
  };

  nodes.client = {
    networking.firewall.allowedUDPPorts = [ 123 ];
    environment.systemPackages = [ pkgs.talosctl ];
    environment.variables.TALOSCONFIG = "${talosConfig}/talosconfig";

    # talos syncs time from this node, so the vm is exercised in both directions
    services.chrony = {
      enable = true;
      servers = [ ];
      extraConfig = ''
        local stratum 10
        allow 192.168.1.0/24
      '';
    };
  };

  testScript = ''
    start_all()

    client.wait_for_unit("chronyd.service")

    with subtest("nixos -> talos api"):
        client.wait_until_succeeds("talosctl -n talos -e talos version", timeout=300)
        client.log(client.succeed("talosctl -n talos -e talos get addresses"))
        client.succeed("talosctl -n talos -e talos service apid | grep -i running")

    with subtest("talos -> nixos ntp"):
        client.wait_until_succeeds(
            "talosctl -n talos -e talos get timestatus -o yaml | grep 'synced: true'",
            timeout=300,
        )
        client.succeed("chronyc -n clients | grep ${ip}")
  '';
}
