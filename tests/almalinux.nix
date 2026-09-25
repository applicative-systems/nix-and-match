{ foreign, images, ... }:
let
  vm = foreign.mkForeignVM {
    name = "alma";
    inherit (images.almalinux) image format;
    ip = "192.168.1.100";
    userData = foreign.backdoorCloudConfig { hosts = "192.168.1.1 server\n"; };
  };
in
{
  name = "alma-interop";

  nodes.server = {
    networking.extraHosts = "192.168.1.100 alma";
    networking.firewall.allowedTCPPorts = [ 80 ];
    services.nginx = {
      enable = true;
      virtualHosts.server.locations."/".return = "200 'hello from nixos'";
    };
  };

  testScript = ''
    alma = create_machine("${vm}")
    # registered so start_all() and driver cleanup cover it
    machines_qemu.append(alma)

    start_all()

    server.wait_for_unit("nginx.service")
    alma.succeed("cloud-init status --wait")
    alma.log(alma.succeed("grep PRETTY_NAME /etc/os-release"))

    with subtest("foreign -> nixos"):
        alma.succeed("curl -sf http://server/ | grep 'hello from nixos'")

    with subtest("nixos -> foreign"):
        alma.succeed("systemd-run --unit=web python3 -m http.server 8000 -d /etc")
        server.wait_until_succeeds("curl -sf http://alma:8000/os-release | grep -i almalinux")
  '';
}
