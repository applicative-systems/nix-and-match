# $QEMU_OPTS reaches foreign VMs, as it reaches NixOS VMs. The check sets it
# with overrideTestDerivation; interactively, it comes from the environment.
{
  name = "qemu-opts";

  foreignNodes.guest.image = "debian-13";

  testScript = ''
    guest.succeed("grep -x nix-and-match /sys/class/dmi/id/product_serial")
  '';
}
