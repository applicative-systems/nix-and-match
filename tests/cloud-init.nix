# shared by all images with a cloud-init provisioner
image:
{ hostPkgs, ... }:
let
  inherit ((import ../lib/images.nix { pkgs = hostPkgs; }).${image}) virtiofs;
in
{
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
    # the guest has the host's architecture
    guest.succeed("test $(uname -m) = ${hostPkgs.stdenv.hostPlatform.uname.processor}")

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

  ''
  + (
    if virtiofs then
      ''
        with subtest("copy_from_host"):
            src = guest.out_dir / "to-guest"
            src.mkdir()
            (src / "file").write_text("from the host\n")
            guest.copy_from_host(str(src), "/root/to-guest")
            guest.succeed("grep -x 'from the host' /root/to-guest/file")

        with subtest("copy_from_machine"):
            guest.succeed("echo 'from the guest' > /root/from-guest")
            guest.copy_from_machine("/root/from-guest", "copied")
            assert (guest.out_dir / "copied" / "from-guest").read_text() == "from the guest\n"

        with subtest("shared with nixos nodes"):
            guest.succeed("echo foreign > /tmp/shared/guest-file")
            server.succeed("grep -x foreign /tmp/shared/guest-file")
            server.succeed("echo nixos > /tmp/shared/server-file")
            guest.succeed("grep -x nixos /tmp/shared/server-file")
            guest.succeed("findmnt -t virtiofs /tmp/xchg")
      ''
    else
      ''
        with subtest("no virtiofs, copy_from_host_via_shell"):
            guest.fail("findmnt /tmp/shared")
            src = guest.out_dir / "to-guest"
            src.write_text("from the host\n")
            guest.copy_from_host_via_shell(str(src), "/root/to-guest")
            guest.succeed("grep -x 'from the host' /root/to-guest")
      ''
  )
  + ''
    with subtest("shell survives isolate"):
        guest.succeed("systemctl isolate rescue.target")
        guest.succeed("systemctl is-active rescue.target")
  '';
}
