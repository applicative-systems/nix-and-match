{
  pkgs,
  foreign,
  images,
  ...
}:
let
  # no shell on talos: it gets a machine config via nocloud user-data and is driven through its API
  talosConfig = pkgs.runCommand "talos-config" { nativeBuildInputs = [ pkgs.talosctl ]; } ''
    export HOME=$TMPDIR
    talosctl gen config interop https://192.168.1.100:6443 \
      --talos-version v${images.talos.version} --install-disk /dev/vda --with-docs=false --with-examples=false \
      --config-patch '{"machine":{"time":{"servers":["192.168.1.1"]}}}' \
      -o $out
  '';

  vm = foreign.mkForeignVM {
    name = "talos";
    inherit (images.talos) image format;
    ip = "192.168.1.100";
    userDataFile = "${talosConfig}/controlplane.yaml";
  };
in
{
  name = "talos-interop";

  nodes.client = {
    networking.extraHosts = "192.168.1.100 talos";
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
    talos = create_machine("${vm}")
    # registered so start_all() and driver cleanup cover it
    machines_qemu.append(talos)

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
        client.succeed("chronyc -n clients | grep 192.168.1.100")
  '';
}
