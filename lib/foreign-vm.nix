{ pkgs }:
let
  inherit (pkgs) lib;
  toYAML = lib.generators.toYAML { };
  qemuCommon = import "${pkgs.path}/nixos/lib/qemu-common.nix" { inherit lib; inherit (pkgs) stdenv; };

  # same wire protocol as nixos/modules/testing/test-instrumentation.nix
  backdoorScript = ''
    #!/bin/bash
    export USER=root HOME=/root PAGER= SYSTEMD_PAGER=
    [ -e /etc/profile ] && source /etc/profile
    cd /tmp
    exec < /dev/hvc0 > /dev/hvc0
    while ! exec 2> /dev/ttyS0; do sleep 0.1; done
    echo "connecting to host..." >&2
    stty -F /dev/hvc0 raw -echo
    echo "Spawning backdoor root shell..."
    PS1="" exec /bin/bash --norc /dev/hvc0
  '';

  backdoorUnit = ''
    [Unit]
    Requires=dev-hvc0.device dev-ttyS0.device
    After=dev-hvc0.device dev-ttyS0.device
    [Service]
    ExecStart=/bin/bash /usr/local/sbin/nixos-test-backdoor
    KillSignal=SIGHUP
    [Install]
    WantedBy=multi-user.target
  '';

  # cloud-config that makes a cloud-init distro drivable by the test driver
  backdoorCloudConfig =
    { hosts ? "" }:
    "#cloud-config\n"
    + toYAML {
      write_files = [
        {
          path = "/usr/local/sbin/nixos-test-backdoor";
          permissions = "0755";
          content = backdoorScript;
        }
        {
          path = "/etc/systemd/system/nixos-test-backdoor.service";
          content = backdoorUnit;
        }
        {
          path = "/etc/hosts";
          append = true;
          content = hosts;
        }
      ];
      # systemd-getty-generator would otherwise grab hvc0
      bootcmd = [ [ "systemctl" "mask" "--now" "serial-getty@hvc0.service" ] ];
      runcmd = [
        [ "systemctl" "daemon-reload" ]
        [ "systemctl" "start" "--no-block" "nixos-test-backdoor.service" ]
      ];
    };

  mkSeed =
    {
      name,
      userDataFile,
      networkConfig,
    }:
    pkgs.runCommand "${name}-cidata.iso" { nativeBuildInputs = [ pkgs.cdrkit ]; } ''
      mkdir cidata && cd cidata
      printf 'instance-id: ${name}\nlocal-hostname: ${name}\n' > meta-data
      cp ${userDataFile} user-data
      cp ${pkgs.writeText "network-config" (toYAML networkConfig)} network-config
      genisoimage -quiet -output $out -volid cidata -joliet -rock .
    '';
in
{
  inherit backdoorCloudConfig;

  # start command for `create_machine`; the `run-<name>-vm` suffix gives the machine its name
  mkForeignVM =
    {
      name,
      image,
      format,
      # nixos test nodes use 192.168.<vlan>.<node index>, so stay clear of low numbers
      ip,
      vlan ? 1,
      memory ? 2048,
      cores ? 2,
      diskSize ? "10G",
      userData ? "",
      userDataFile ? pkgs.writeText "user-data" userData,
    }:
    let
      hostByte = lib.last (lib.splitString "." ip);
      mac = "52:54:00:12:${lib.fixedWidthString 2 "0" (lib.toHexString vlan)}:${
        lib.fixedWidthString 2 "0" (lib.toHexString (lib.toInt hostByte))
      }";
      seed = mkSeed {
        inherit name userDataFile;
        networkConfig = {
          version = 2;
          ethernets.eth0 = {
            match.macaddress = mac;
            addresses = [ "${ip}/24" ];
          };
        };
      };
      qemu = pkgs.qemu_test;
    in
    pkgs.writeShellScript "run-${name}-vm" ''
      set -eu
      disk="$TMPDIR/${name}.qcow2"
      if [ ! -e "$disk" ]; then
        ${qemu}/bin/qemu-img create -q -f qcow2 -F ${format} -b ${image} "$disk" ${diskSize}
      fi
      exec ${qemuCommon.qemuBinary qemu} \
        -name ${name} -m ${toString memory} -smp ${toString cores} \
        -drive file="$disk",if=virtio \
        -drive file=${seed},if=virtio,media=cdrom,readonly=on \
        -netdev vde,id=vlan${toString vlan},sock="$QEMU_VDE_SOCKET_${toString vlan}" \
        -device virtio-net-pci,netdev=vlan${toString vlan},mac=${mac} \
        "$@"
    '';
}
