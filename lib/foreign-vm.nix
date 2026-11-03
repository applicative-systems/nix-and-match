{ pkgs }:
let
  inherit (pkgs) lib;
  toYAML = lib.generators.toYAML { };
  inherit (pkgs.stdenv.hostPlatform) system;
  qemu = pkgs.qemu_test;

  # guests always have the host's system and run with KVM
  machine =
    {
      x86_64-linux = {
        args = "-machine accel=kvm:tcg -cpu max";
        serial = "ttyS0";
      };
      aarch64-linux = {
        # cloud images boot with UEFI
        args = "-machine virt,gic-version=max,accel=kvm:tcg -cpu max -bios ${qemu}/share/qemu/edk2-aarch64-code.fd";
        serial = "ttyAMA0";
      };
    }
    .${system} or (throw "foreign nodes are not supported on ${system}");

  # same wire protocol as nixos/modules/testing/test-instrumentation.nix
  backdoorScript = serial: ''
    #!/bin/bash
    export USER=root HOME=/root PAGER= SYSTEMD_PAGER=
    [ -e /etc/profile ] && source /etc/profile
    cd /tmp
    exec < /dev/hvc0 > /dev/hvc0
    while ! exec 2> /dev/${serial}; do sleep 0.1; done
    echo "connecting to host..." >&2
    stty -F /dev/hvc0 raw -echo
    echo "Spawning backdoor root shell..."
    PS1="" exec /bin/bash --norc /dev/hvc0
  '';

  # runcmd runs inside cloud-final.service, so ordering after it makes the
  # shell, and with it the first `succeed`, wait until provisioning is done
  backdoorUnit = serial: ''
    [Unit]
    Requires=dev-hvc0.device dev-${serial}.device
    After=dev-hvc0.device dev-${serial}.device cloud-final.service
    # keep the shell when the test switches targets, e.g. to rescue.target
    IgnoreOnIsolate=true
    [Service]
    ExecStart=/bin/bash /usr/local/sbin/nixos-test-backdoor
    KillSignal=SIGHUP
    [Install]
    WantedBy=multi-user.target
  '';

  # cloud-config merge: maps recursively, lists appended, other values from `b`
  mergeCloudConfig =
    a: b:
    if lib.isAttrs a && lib.isAttrs b then
      lib.zipAttrsWith
        (
          _: values:
          if lib.length values == 1 then
            lib.head values
          else
            mergeCloudConfig (lib.head values) (lib.last values)
        )
        [
          a
          b
        ]
    else if lib.isList a && lib.isList b then
      a ++ b
    else
      b;

  # what every cloud-init guest needs to be part of the test network
  networkCloudConfig =
    {
      hosts,
      ip,
      ip6,
    }:
    {
      write_files = [
        {
          path = "/etc/hosts";
          append = true;
          content = hosts;
        }
      ];
      # no time server on the test network: arch would wait for one forever
      bootcmd = [
        [
          "sh"
          "-c"
          "systemctl mask --now systemd-time-wait-sync.service || true"
        ]
      ];
      # amazon's cloud-init loses the addresses if there is more than one
      runcmd = [
        [
          "ip"
          "address"
          "replace"
          "${ip}/24"
          "dev"
          "eth0"
        ]
        [
          "ip"
          "address"
          "replace"
          "${ip6}/64"
          "dev"
          "eth0"
        ]
      ];
    };

  # the test driver's root shell on hvc0, logging to the serial console
  shellCloudConfig = {
    write_files = [
      {
        path = "/usr/local/sbin/nixos-test-backdoor";
        permissions = "0755";
        content = backdoorScript machine.serial;
      }
      {
        path = "/etc/systemd/system/nixos-test-backdoor.service";
        content = backdoorUnit machine.serial;
      }
    ];
    # systemd-getty-generator would otherwise grab hvc0
    bootcmd = [
      [
        "systemctl"
        "mask"
        "--now"
        "serial-getty@hvc0.service"
      ]
    ];
    runcmd = [
      [
        "systemctl"
        "daemon-reload"
      ]
      [
        "systemctl"
        "start"
        "--no-block"
        "nixos-test-backdoor.service"
      ]
    ];
  };

  # cloud-config parts generated for a guest: network setup, then the shell
  generatedCloudConfig =
    {
      hosts,
      ip,
      ip6,
      shell,
    }:
    mergeCloudConfig (networkCloudConfig { inherit hosts ip ip6; }) (
      lib.optionalAttrs shell shellCloudConfig
    );

  cloudConfigFile =
    name: config: pkgs.writeText "${name}-user-data" ("#cloud-config\n" + toYAML config);

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
  # user-data for provisioner = "cloud-init": one cloud-config
  cloudInitUserData =
    {
      name,
      hosts,
      ip,
      ip6,
      shell,
      extraConfig,
    }:
    cloudConfigFile name (
      mergeCloudConfig (generatedCloudConfig {
        inherit
          hosts
          ip
          ip6
          shell
          ;
      }) extraConfig
    );

  # user-data for provisioner = "custom": the user's file unchanged, followed
  # by the generated cloud-config, which cloud-init merges into it
  customUserData =
    {
      name,
      hosts,
      ip,
      ip6,
      shell,
      userData,
    }:
    let
      generated = cloudConfigFile "${name}-generated" (
        generatedCloudConfig {
          inherit
            hosts
            ip
            ip6
            shell
            ;
        }
        // {
          merge_how = [
            {
              name = "list";
              settings = [ "append" ];
            }
            {
              name = "dict";
              settings = [
                "no_replace"
                "recurse_list"
              ];
            }
          ];
        }
      );
      boundary = "==nix-and-match-part==";
    in
    pkgs.runCommand "${name}-user-data" { } ''
      part() {
        printf -- '--%s\nContent-Type: text/plain; charset="utf-8"\nMIME-Version: 1.0\n\n' '${boundary}'
        cat "$1"
        printf '\n'
      }
      {
        printf 'Content-Type: multipart/mixed; boundary="%s"\nMIME-Version: 1.0\n\n' '${boundary}'
        part ${userData}
        part ${generated}
        printf -- '--%s--\n' '${boundary}'
      } > $out
    '';

  # start script for the test driver
  mkForeignVM =
    {
      name,
      image,
      format,
      ip,
      ip6,
      vlan ? 1,
      memorySize ? 2048,
      cores ? 2,
      diskSize ? "10G",
      userDataFile,
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
            # amazon's cloud-init crashes if the key isn't the interface's real name
            set-name = "eth0";
            addresses = [
              "${ip}/24"
              "${ip6}/64"
            ];
          };
        };
      };
    in
    pkgs.writeShellScript "run-${name}-vm" ''
      set -eu
      disk="$TMPDIR/${name}.qcow2"
      if [ ! -e "$disk" ]; then
        ${qemu}/bin/qemu-img create -q -f qcow2 -F ${format} -b ${image} "$disk"
        # grow only: qemu-img refuses to shrink, which would cut off larger images
        ${qemu}/bin/qemu-img resize -q "$disk" ${diskSize} 2>/dev/null ||
          echo "${name}: disk stays at the image's size, which is larger than ${diskSize}" >&2
      fi
      exec ${qemu}/bin/qemu-system-${pkgs.stdenv.hostPlatform.qemuArch} ${machine.args} \
        -name ${name} -m ${toString memorySize} -smp ${toString cores} \
        -device virtio-rng-pci \
        -drive file="$disk",if=virtio \
        -drive file=${seed},if=virtio,media=cdrom,readonly=on \
        -netdev vde,id=vlan${toString vlan},sock="$QEMU_VDE_SOCKET_${toString vlan}" \
        -device virtio-net-pci,netdev=vlan${toString vlan},mac=${mac} \
        "$@"
    '';
}
