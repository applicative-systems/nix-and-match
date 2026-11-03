# shared by all images with a cloud-init provisioner
image: {
  name = "${image}-interop";

  foreignNodes.guest.image = image;

  nodes.server = {
    networking.firewall.allowedTCPPorts = [ 80 ];
    services.nginx = {
      enable = true;
      virtualHosts.server.locations."/".return = "200 'hello from nixos'";
    };
  };

  testScript = ''
    start_all()

    server.wait_for_unit("nginx.service")
    # the shell only starts once cloud-init is done
    guest.log(guest.succeed("cloud-init status --long || true"))
    guest.fail("cloud-init status | grep running")
    guest.log(guest.succeed("grep PRETTY_NAME /etc/os-release"))

    with subtest("foreign -> nixos"):
        guest.succeed("curl -sf http://server/ | grep 'hello from nixos'")

    with subtest("nixos -> foreign"):
        # active by default on oracle
        guest.execute("systemctl stop firewalld")
        guest.succeed("systemd-run --unit=web python3 -m http.server 8000 -d /etc")
        server.wait_until_succeeds("curl -sf http://guest:8000/os-release | grep PRETTY_NAME")

    with subtest("virtio rng"):
        # device id 4 is the entropy source; whether a driver uses it is up to the distro
        guest.succeed("grep -x 0x0004 /sys/bus/virtio/devices/*/device")

    with subtest("shell survives isolate"):
        guest.succeed("systemctl isolate rescue.target")
        guest.succeed("systemctl is-active rescue.target")
  '';
}
