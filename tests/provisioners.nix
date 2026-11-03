# every provisioner, with and without shell, in one test network
{ config, hostPkgs, ... }:
let
  pkgs = hostPkgs;
  images = import ../lib/images.nix { inherit pkgs; };
  serverIp = config.nodes.server.networking.primaryIPAddress;
  talosIp = config.nodes.talos.networking.primaryIPAddress;

  talosConfig = import ./talos-config.nix {
    inherit pkgs;
    inherit (images."talos-1.14".pins.${pkgs.stdenv.hostPlatform.system}) version;
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
      memorySize = 1536;
      cores = 1;
      diskSize = "+3G";
      sharedDirectories = {
        data = {
          source = "${pkgs.writeTextDir "message" "from the store\n"}";
          target = "/srv/data";
        };
        results = {
          source = ''"$TMPDIR"/results'';
          target = "/srv/results";
          writable = true;
        };
      };
      cloudInit.config = {
        write_files = [
          {
            path = "/etc/greeting";
            content = "from cloudInit.config";
          }
        ];
        runcmd = [
          # readiness: the shell must not be there before this is done
          "sleep 15 && touch /run/provisioned"
          # shares are mounted before
          "cp /srv/data/message /run/message"
        ];
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

    # no shell: only visible from the network. It serves a shared folder.
    silent = {
      image = "almalinux-9";
      shell = false;
      sharedDirectories.www = {
        source = "${pkgs.writeTextDir "index.html" "silent machine"}";
        target = "/srv/www";
      };
      cloudInit.config.runcmd = [ "systemd-run --unit=web python3 -m http.server 8000 -d /srv/www" ];
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

    with subtest("machine sizes"):
        configured.succeed("test $(nproc) -eq 1")
        # MemTotal excludes what the kernel reserves
        configured.succeed("awk '/MemTotal/ { exit !($2 > 1300000 && $2 <= 1536 * 1024) }' /proc/meminfo")
        # debian's image is 3G, plus 3G
        configured.succeed("test $(lsblk -bdno SIZE /dev/vda) -eq $((6 * 1024 ** 3))")
        # cloud-init grew the root file system
        configured.succeed("test $(df -B1 --output=size / | tail -n 1) -gt $((5 * 1024 ** 3))")
        # amazon's image is 25G, more than the default 10G
        merged.succeed("test $(lsblk -bdno SIZE /dev/vda) -eq $((25 * 1024 ** 3))")

    with subtest("shared directories"):
        configured.succeed("grep -x 'from the store' /run/message")
        configured.fail("touch /srv/data/new")
        configured.succeed("echo result > /srv/results/out")
        assert (configured.state_dir / "results" / "out").read_text() == "result\n"
        # the defaults are still there
        configured.succeed("findmnt -t virtiofs /tmp/shared")

    with subtest("custom: script runs, shell, network and shares are added"):
        scripted.succeed("grep 'from a script' /run/provisioned")
        scripted.succeed("curl -sf http://server/ | grep 'hello from nixos'")
        scripted.succeed("findmnt -t virtiofs /tmp/shared")

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
