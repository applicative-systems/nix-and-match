# Foreign VMs and the test framework's systemd-nspawn containers share the
# test network: they find each other by name and talk both ways.
{
  name = "containers";

  foreignNodes.guest.image = "debian-13";

  containers.web = {
    networking.firewall.allowedTCPPorts = [ 80 ];
    services.nginx = {
      enable = true;
      virtualHosts.web.locations."/".return = "200 'hello from a container'";
    };
  };

  testScript = ''
    start_all()
    web.wait_for_unit("nginx.service")

    with subtest("foreign -> container"):
        guest.succeed("ping -c 1 web")
        guest.succeed("curl -sf http://web/ | grep 'hello from a container'")

    with subtest("container -> foreign"):
        guest.succeed("systemd-run --unit=files python3 -m http.server 8000 -d /etc")
        web.succeed("ping -c 1 guest")
        web.wait_until_succeeds("curl -sf http://guest:8000/os-release | grep PRETTY_NAME")
  '';
}
