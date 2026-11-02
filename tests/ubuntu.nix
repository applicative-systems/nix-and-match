{
  name = "ubuntu-interop";

  foreignNodes.ubuntu.image = "ubuntu-24.04";

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
    ubuntu.succeed("cloud-init status --wait")
    ubuntu.log(ubuntu.succeed("grep PRETTY_NAME /etc/os-release"))

    with subtest("foreign -> nixos"):
        ubuntu.succeed("curl -sf http://server/ | grep 'hello from nixos'")

    with subtest("nixos -> foreign"):
        ubuntu.succeed("systemd-run --unit=web python3 -m http.server 8000 -d /etc")
        server.wait_until_succeeds("curl -sf http://ubuntu:8000/os-release | grep -i ubuntu")
  '';
}
