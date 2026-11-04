{ pkgs }:
let
  inherit (pkgs) lib;
  toYAML = lib.generators.toYAML { };
  qemu = pkgs.qemu_test;

  # the same helpers that NixOS test VMs use, so foreign VMs get the same
  # machine type, serial console and NICs. Guests have the host's system.
  qemuCommon = import "${pkgs.path}/nixos/lib/qemu-common.nix" {
    inherit lib;
    inherit (pkgs) stdenv;
  };
  qemuBinary =
    qemuCommon.qemuBinary qemu
    # cloud images boot with UEFI, NixOS test VMs boot their kernel directly
    + lib.optionalString pkgs.stdenv.hostPlatform.isAarch64 " -bios ${qemu}/share/qemu/edk2-aarch64-code.fd";
  serial = qemuCommon.qemuSerialDevice;

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
    # SUSE's /etc/profile exports a read-only PROFILEREAD, after which login
    # shells started from this one would skip /etc/profile.d
    PS1="" exec env -u PROFILEREAD /bin/bash --norc /dev/hvc0
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
    # an unconfined root shell, as an admin's login: some SELinux policies
    # confine services, so that `su` fails. `-`: ignored without SELinux.
    SELinuxContext=-unconfined_u:unconfined_r:unconfined_t:s0-s0:c0.c1023
    [Install]
    # not multi-user.target: cloud-final.service runs after that, so the
    # ordering above would be a cycle
    WantedBy=cloud-final.service
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
        # amazon's cloud-init loses the addresses if there is more than one.
        # Runs in cloud-final.service on every boot, before the shell starts.
        {
          path = "/var/lib/cloud/scripts/per-boot/nix-and-match-addresses";
          permissions = "0755";
          content = ''
            #!/bin/sh
            ip address replace ${ip}/24 dev eth0
            ip address replace ${ip6}/64 dev eth0
          '';
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
    };

  # the test driver's root shell on hvc0, logging to the serial console
  shellCloudConfig = {
    write_files = [
      {
        path = "/usr/local/sbin/nixos-test-backdoor";
        permissions = "0755";
        content = backdoorScript serial;
      }
      {
        path = "/etc/systemd/system/nixos-test-backdoor.service";
        content = backdoorUnit serial;
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
    # enabled, so the shell is back after `shutdown()` and `start()`
    runcmd = [
      [
        "systemctl"
        "daemon-reload"
      ]
      [
        "systemctl"
        "enable"
        "--now"
        "--no-block"
        "nixos-test-backdoor.service"
      ]
    ];
  };

  # virtiofs shares, mounted from runcmd: earlier stages can run before /tmp is
  # mounted, which would hide the shares under it. runcmd only runs on the
  # first boot, so the mounts also go to /etc/fstab for later boots.
  sharesCloudConfig =
    shares:
    lib.optionalAttrs (shares != { }) {
      runcmd = lib.mapAttrsToList (
        tag: share:
        let
          mode = if share.writable then "rw" else "ro";
          # SELinux doesn't let systemd start programs from an unlabeled
          # file system, so the Nix store gets the label of /usr/bin
          options =
            if share.source == builtins.storeDir then
              "$([ -e /sys/fs/selinux/enforce ] && echo ${mode},context=system_u:object_r:bin_t:s0 || echo ${mode})"
            else
              mode;
        in
        [
          "sh"
          "-c"
          (lib.concatStringsSep " && " [
            "o=${options}"
            "mkdir -p ${share.target}"
            "mount -t virtiofs -o $o ${tag} ${share.target}"
            "echo \"${tag} ${share.target} virtiofs $o,nofail 0 0\" >> /etc/fstab"
          ])
        ]
      ) shares;
    };

  # cloud-config parts generated for a guest: network setup, shares, then the shell
  generatedCloudConfig =
    {
      hosts,
      ip,
      ip6,
      shares,
      shell,
    }:
    lib.foldl' mergeCloudConfig (networkCloudConfig { inherit hosts ip ip6; }) [
      (sharesCloudConfig shares)
      (lib.optionalAttrs shell shellCloudConfig)
    ];

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
      shares,
      shell,
      extraConfig,
    }:
    cloudConfigFile name (
      mergeCloudConfig (generatedCloudConfig {
        inherit
          hosts
          ip
          ip6
          shares
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
      shares,
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
            shares
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
      # virtualisation.test.nodeNumber of the node
      nodeNumber,
      vlan ? 1,
      memorySize ? 2048,
      cores ? 2,
      diskSize ? "10G",
      # tag -> { source, target, writable }, as virtualisation.sharedDirectories;
      # `source` is a shell expression
      shares ? { },
      # store paths the machine uses from the shared Nix store
      additionalPaths ? [ ],
      userDataFile,
    }:
    let
      mac = qemuCommon.qemuNicMac vlan nodeNumber;
      # one virtiofsd per share, as NixOS test VMs do (see qemu-vm.nix)
      startVirtiofsd = tag: share: ''
        ${lib.optionalString share.writable "mkdir -p ${share.source}"}
        ${lib.getExe pkgs.virtiofsd} \
          --socket-path="$virtiofs/${tag}" \
          --shared-dir=${share.source} \
          ${if share.writable then "--writeback" else "--readonly"} \
          --sandbox=none \
          --seccomp=none \
          --cache=always \
          --no-announce-submounts \
          --translate-uid=host:65534:0:1 \
          --translate-gid=host:65534:0:1 \
          &
      '';
      # QEMU fails if a socket isn't there yet
      waitVirtiofsd = tag: _: ''
        for _ in {1..100}; do [ -S "$virtiofs/${tag}" ] && break; sleep 0.1; done
      '';
      sharesFlags = lib.optionals (shares != { }) (
        [
          # vhost-user needs memory that virtiofsd can map
          "-object memory-backend-memfd,id=mem0,size=${toString memorySize}M,share=on"
          "-machine memory-backend=mem0"
        ]
        ++ lib.concatLists (
          lib.mapAttrsToList (tag: _: [
            "-chardev socket,id=${tag},path=\"$virtiofs/${tag}\""
            "-device vhost-user-fs-pci,chardev=${tag},tag=${tag}"
          ]) shares
        )
      );
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
      ${lib.optionalString (additionalPaths != [ ]) ''
        # referenced, so that they are in the test's sandbox:
        # ${toString additionalPaths}
      ''}
      disk="$TMPDIR/${name}.qcow2"
      if [ ! -e "$disk" ]; then
        ${qemu}/bin/qemu-img create -q -f qcow2 -F ${format} -b ${image} "$disk"
        # grow only: qemu-img refuses to shrink, which would cut off larger images
        ${qemu}/bin/qemu-img resize -q "$disk" ${diskSize} 2>/dev/null ||
          echo "${name}: disk stays at the image's size, which is larger than ${diskSize}" >&2
      fi
      ${lib.optionalString (shares != { }) ''
        virtiofs=$(mktemp -d)
        ${lib.concatLines (lib.mapAttrsToList startVirtiofsd shares)}
        ${lib.concatLines (lib.mapAttrsToList waitVirtiofsd shares)}
      ''}
      exec ${qemuBinary} \
        -name ${name} -m ${toString memorySize} -smp ${toString cores} \
        -device virtio-rng-pci \
        -drive file="$disk",if=virtio \
        -drive file=${seed},if=virtio,media=cdrom,readonly=on \
        ${lib.concatStringsSep " " (qemuCommon.qemuNICFlags 1 vlan nodeNumber)} \
        ${lib.concatStringsSep " " sharesFlags} \
        ''${QEMU_OPTS:-} \
        "$@"
    '';
}
