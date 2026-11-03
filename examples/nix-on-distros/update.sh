# Pins the newest NixOS nix-installer release in pins.json. Run from the
# repository root: nix run .#update-examples
#
# GitHub publishes SHA256SUMS without a signature, so the hashes are read
# over https, as `checksum-only` images are.

pins=examples/nix-on-distros/pins.json
repo=NixOS/nix-installer

version=$(curl -fsSL --retry 3 "https://api.github.com/repos/$repo/releases/latest" | jq -r .tag_name)
sums=$(curl -fsSL --retry 3 "https://github.com/$repo/releases/download/$version/SHA256SUMS")

sri() {
  local hex
  hex=$(awk -v file="$1" '$2 == file { print $1 }' <<<"$sums")
  [[ $hex =~ ^[0-9a-f]{64}$ ]] || {
    echo "no checksum for $1" >&2
    return 1
  }
  nix --extra-experimental-features nix-command hash convert --hash-algo sha256 --to sri "$hex"
}

jq -n -S \
  --arg version "$version" \
  --arg script "$(sri nix-installer.sh)" \
  --arg x86_64 "$(sri nix-installer-x86_64-linux)" \
  --arg aarch64 "$(sri nix-installer-aarch64-linux)" '
  {
    "nix-installer": {
      $version,
      verification: "checksum-only",
      hashes: {
        "nix-installer.sh": $script,
        "nix-installer-x86_64-linux": $x86_64,
        "nix-installer-aarch64-linux": $aarch64
      }
    }
  }' >"$pins"
echo "nix-installer: $version"
