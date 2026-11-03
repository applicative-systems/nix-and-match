# machine config and talosconfig for a single-node Talos cluster at `ip`,
# syncing time from `timeServer` as there is no internet in the test
{
  pkgs,
  version,
  ip,
  timeServer,
}:
pkgs.runCommand "talos-config" { nativeBuildInputs = [ pkgs.talosctl ]; } ''
  export HOME=$TMPDIR
  talosctl gen config interop https://${ip}:6443 \
    --talos-version v${version} --install-disk /dev/vda --with-docs=false --with-examples=false \
    --config-patch '{"machine":{"time":{"servers":["${timeServer}"]}}}' \
    -o $out
''
