{ foreign, images, ... }:
let
  vm = foreign.mkForeignVM {
    name = "ubuntu";
    inherit (images.ubuntu) image format;
    ip = "192.168.1.100";
    userData = foreign.backdoorCloudConfig { hosts = "192.168.1.1 server\n"; };
  };
in
{
  name = "ubuntu-interop";

  nodes.server = {
    networking.extraHosts = "192.168.1.100 ubuntu";
    networking.firewall.allowedTCPPorts = [ 80 ];
    services.nginx = {
      enable = true;
      virtualHosts.server.locations."/".return = "200 'hello from nixos'";
    };
  };

  testScript = ''
    ubuntu = create_machine("${vm}")
    # registered so start_all() and driver cleanup cover it
    machines_qemu.append(ubuntu)

    start_all()

    server.wait_for_unit("nginx.service")
    ubuntu.succeed("cloud-init status --wait")
    ubuntu.log(ubuntu.succeed("grep PRETTY_NAME /etc/os-release"))

    with subtest("foreign -> nixos"):
        ubuntu.succeed("curl -sf http://server/ | grep 'hello from nixos'")

    with subtest("nixos -> foreign"):
        ubuntu.succeed("systemd-run --unit=web python3 -m http.server 8000 -d /etc")
        server.wait_until_succeeds("curl -sf http://ubuntu:8000/os-release | grep -i ubuntu")
  '';
}
