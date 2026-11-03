# every provisioner, with and without shell, in one test network
{ config, hostPkgs, ... }:
let
  pkgs = hostPkgs;
  images = import ../lib/images.nix { inherit pkgs; };
  serverIp = config.nodes.server.networking.primaryIPAddress;
  talosIp = config.nodes.talos.networking.primaryIPAddress;

  talosConfig = import ./talos-config.nix {
    inherit pkgs;
    inherit (images."talos-1.14") version;
    ip = talosIp;
    timeServer = serverIp;
  };
in
{
  name = "provisioners";

  foreignNodes = {
    # generated cloud-config plus our own settings
    configured = {
      image = "debian-13";
      cloudInit.config = {
        write_files = [
          {
            path = "/etc/greeting";
            content = "from cloudInit.config";
          }
        ];
        # readiness: the shell must not be there before this is done
        runcmd = [ "sleep 15 && touch /run/provisioned" ];
      };
    };

    # a user-data script, not a cloud-config, with the shell added
    scripted = {
      image = "ubuntu-24.04";
      provisioner = "custom";
      userData = pkgs.writeText "user-data.sh" ''
        #!/bin/sh
        sleep 15
        echo "from a script" > /run/provisioned
      '';
    };

    # our own cloud-config, merged with the generated one by the oldest cloud-init
    merged = {
      image = "amazon-2023";
      provisioner = "custom";
      userData = pkgs.writeText "user-data.yaml" ''
        #cloud-config
        write_files:
          - path: /etc/greeting
            content: from userData
        runcmd:
          - sleep 15 && touch /run/provisioned
      '';
    };

    # no shell: only visible from the network
    silent = {
      image = "almalinux-9";
      shell = false;
      cloudInit.config = {
        write_files = [
          {
            path = "/srv/index.html";
            content = "silent machine";
          }
        ];
        runcmd = [ "systemd-run --unit=web python3 -m http.server 8000 -d /srv" ];
      };
    };

    # no cloud-init: the seed is the machine config
    talos = {
      image = "talos-1.14";
      userData = "${talosConfig}/controlplane.yaml";
    };
  };

  nodes.server = {
    networking.firewall.allowedTCPPorts = [ 80 ];
    networking.firewall.allowedUDPPorts = [ 123 ];
    services.nginx = {
      enable = true;
      virtualHosts.server.locations."/".return = "200 'hello from nixos'";
    };
    services.chrony = {
      enable = true;
      servers = [ ];
      extraConfig = ''
        local stratum 10
        allow 192.168.1.0/24
      '';
    };
    environment.systemPackages = [ pkgs.talosctl ];
    environment.variables.TALOSCONFIG = "${talosConfig}/talosconfig";
  };

  testScript = ''
    start_all()
    server.wait_for_unit("nginx.service")

    with subtest("cloud-init: settings applied before the shell starts"):
        configured.succeed("test -e /run/provisioned")
        configured.succeed("grep 'from cloudInit.config' /etc/greeting")
        configured.succeed("curl -sf http://server/ | grep 'hello from nixos'")

    with subtest("custom: script runs, shell and network are added"):
        scripted.succeed("grep 'from a script' /run/provisioned")
        scripted.succeed("curl -sf http://server/ | grep 'hello from nixos'")

    with subtest("custom: cloud-config merged with the generated one"):
        merged.succeed("test -e /run/provisioned")
        merged.succeed("grep 'from userData' /etc/greeting")
        merged.succeed("curl -sf http://server/ | grep 'hello from nixos'")

    with subtest("shell = false: reachable over the network"):
        server.wait_until_succeeds("curl -sf http://silent:8000/ | grep 'silent machine'", timeout=300)

    with subtest("none: talos runs its machine config"):
        server.wait_until_succeeds("talosctl -n talos -e talos version", timeout=300)
        server.succeed("talosctl -n talos -e talos service apid | grep -i running")
  '';
}
