# Refreshes lib/images.json from upstream. Run from the repository root:
#
#   nix run .#update-images                  # all images
#   nix run .#update-images -- debian-13     # selected images
#
# Hashes come from upstream checksum files, so images are not downloaded. Each
# pin records how far it can be trusted in `verification`:
#   signature      checksum file verified against a key in keys/
#   checksum-only  upstream publishes no signature, hash read over https
#   none           no upstream checksum, hash taken from a download

catalog=lib/images.json
keys=keys
all=(
  almalinux-9
  amazon-2023
  arch
  debian-13
  fedora-44
  opensuse-tumbleweed
  oracle-9
  rocky-9
  talos-1.14
  ubuntu-24.04
)
# systems an image is published for, if not all of them
declare -A systems_of=(
  [arch]=x86_64-linux
)
all_systems="x86_64-linux aarch64-linux"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export GNUPGHOME=$work

fetch() {
  curl -fsSL --retry 3 --max-time 60 "$@"
}

save() {
  fetch -o "$work/$2" "$1"
}

# architecture names used by upstream for the system being updated
rpm_arch() {
  case $system in
  x86_64-linux) echo x86_64 ;;
  aarch64-linux) echo aarch64 ;;
  esac
}

deb_arch() {
  case $system in
  x86_64-linux) echo amd64 ;;
  aarch64-linux) echo arm64 ;;
  esac
}

# verify_gpg <key file> <gpgv arguments>
verify_gpg() {
  local key=$1
  shift
  gpg --quiet --yes --dearmor -o "$work/keyring.gpg" "$keys/$key"
  gpgv --quiet --keyring "$work/keyring.gpg" "$@"
}

# Reads "<hash>  <file>", "<hash> *<file>" and "SHA256 (<file>) = <hash>" lines
checksum_of() {
  local hash
  hash=$(awk -v file="$2" '
    $NF == file || $NF == "*" file { print $1 }
    $1 ~ /^SHA/ && $2 == "(" file ")" { print $4 }
  ' "$1")
  if [[ ! $hash =~ ^[0-9a-f]+$ ]]; then
    echo "no unique checksum for $2" >&2
    return 1
  fi
  echo "$hash"
}

# newest <regex>: picks the highest version of the matches on stdin
newest() {
  grep -oE "$1" | sort -uV | tail -n 1
}

# pin <name> <version> <url> <sha256|sha512> <hex hash> <verification> [<compression>]
# pins the image for $system. Images without cloud-init are called as
# `PROVISIONER=none pin ...`.
pin() {
  local name=$1 version=$2 url=$3 algo=$4 hex=$5 verification=$6 compression=${7:-}
  local sri format=qcow2 provisioner=${PROVISIONER:-cloud-init}
  [[ -z $compression ]] || format=raw

  curl -fsIL --retry 3 --max-time 30 -o /dev/null "$url"
  sri=$(nix --extra-experimental-features nix-command hash convert --hash-algo "$algo" --to sri "$hex")

  jq -S \
    --arg name "$name" --arg system "$system" --arg version "$version" --arg url "$url" \
    --arg hash "$sri" --arg format "$format" --arg verification "$verification" \
    --arg compression "$compression" --arg provisioner "$provisioner" '
    .[$name] = {
      $format, $verification, $provisioner,
      systems: (.[$name].systems // {} | .[$system] = { $version, $url, $hash })
    } + (if $compression == "" then {} else { $compression } end)
  ' "$catalog" >"$work/catalog.json"
  cp "$work/catalog.json" "$catalog"
  echo "$name ($system): $version"
}

update_almalinux-9() {
  local arch base file
  arch=$(rpm_arch)
  base=https://repo.almalinux.org/almalinux/9/cloud/$arch/images
  save "$base/CHECKSUM" sums
  save "$base/CHECKSUM.asc" sums.asc
  verify_gpg almalinux-9.asc "$work/sums.asc" "$work/sums"
  file=$(newest "AlmaLinux-9-GenericCloud-9\.[0-9]+-[0-9]{8}\.$arch\.qcow2" <"$work/sums")
  pin almalinux-9 "$(sed -E "s/^AlmaLinux-9-GenericCloud-(.*)\.$arch\.qcow2$/\1/" <<<"$file")" \
    "$base/$file" sha256 "$(checksum_of "$work/sums" "$file")" signature
}

update_amazon-2023() {
  local latest base file arch dir=kvm
  arch=$(rpm_arch)
  if [[ $arch == aarch64 ]]; then
    arch=arm64 dir=kvm-arm64
  fi
  latest=$(curl -fsSIL --retry 3 --max-time 30 -o /dev/null -w '%{url_effective}' \
    https://cdn.amazonlinux.com/al2023/os-images/latest/SHA256SUMS)
  base=${latest%/SHA256SUMS}/$dir
  save "$base/SHA256SUMS" sums
  save "$base/SHA256SUMS.RSASSA_PKCS1_V1_5_SHA_256" sums.sig
  openssl dgst -sha256 -verify "$keys/amazon-2023.pem" -signature "$work/sums.sig" "$work/sums" >/dev/null
  file=$(newest "al2023-kvm-[^ ]*-$arch\.xfs\.gpt\.qcow2" <"$work/sums")
  pin amazon-2023 "$(basename "${base%/"$dir"}")" "$base/$file" sha256 \
    "$(checksum_of "$work/sums" "$file")" signature
}

update_arch() {
  local mirror=https://geo.mirror.pkgbuild.com/images version base file
  version=$(fetch "$mirror/" | newest 'v[0-9]{8}\.[0-9]+')
  base=$mirror/$version
  file=Arch-Linux-x86_64-cloudimg-${version#v}.qcow2
  save "$base/$file.SHA256" sums
  save "$base/$file.SHA256.sig" sums.sig
  verify_gpg arch-boxes.asc "$work/sums.sig" "$work/sums"
  # the checksum file names the unversioned image
  pin arch "${version#v}" "$base/$file" sha256 "$(cut -d ' ' -f 1 "$work/sums")" signature
}

update_debian-13() {
  local mirror=https://cloud.debian.org/images/cloud/trixie version file
  version=$(fetch "$mirror/" | newest '[0-9]{8}-[0-9]{4}')
  file=debian-13-genericcloud-$(deb_arch)-$version.qcow2
  save "$mirror/$version/SHA512SUMS" sums
  pin debian-13 "$version" "$mirror/$version/$file" sha512 \
    "$(checksum_of "$work/sums" "$file")" checksum-only
}

update_fedora-44() {
  local arch base sums file
  arch=$(rpm_arch)
  base=https://dl.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/$arch/images
  sums=$(fetch "$base/" | newest "Fedora-Cloud-44-[0-9.]+-$arch-CHECKSUM")
  save "$base/$sums" sums.signed
  # only trust what is inside the signature, not text around it
  verify_gpg fedora.asc --output "$work/sums" "$work/sums.signed"
  file=$(newest "Fedora-Cloud-Base-Generic-44-[0-9.]+\.$arch\.qcow2" <"$work/sums")
  pin fedora-44 "$(sed -E "s/^Fedora-Cloud-Base-Generic-(.*)\.$arch\.qcow2$/\1/" <<<"$file")" \
    "$base/$file" sha256 "$(checksum_of "$work/sums" "$file")" signature
}

update_opensuse-tumbleweed() {
  local arch base file
  arch=$(rpm_arch)
  base=https://download.opensuse.org/tumbleweed/appliances
  [[ $arch == x86_64 ]] || base=https://download.opensuse.org/ports/$arch/tumbleweed/appliances
  file=$(fetch "$base/?P=*Minimal-VM*Cloud*" |
    newest "openSUSE-Tumbleweed-Minimal-VM\.$arch-[0-9.]+-Cloud-Snapshot[0-9]{8}\.qcow2")
  save "$base/$file.sha256" sums
  save "$base/$file.sha256.asc" sums.asc
  verify_gpg opensuse.asc "$work/sums.asc" "$work/sums"
  pin opensuse-tumbleweed "$(sed -E 's/.*Snapshot([0-9]+)\.qcow2$/\1/' <<<"$file")" "$base/$file" sha256 \
    "$(cut -d ' ' -f 1 "$work/sums")" signature
}

update_oracle-9() {
  local arch page url hash file
  arch=$(rpm_arch)
  page=$(fetch https://yum.oracle.com/oracle-linux-templates.html)
  url=$(newest "https://[^\"]*/OL9/u[0-9]+/$arch/OL9U[0-9]+_$arch-kvm-b[0-9]+\.qcow2" <<<"$page")
  file=$(basename "$url")
  # a row's hashes follow its links
  hash=$(awk -v file="$file" '
    index($0, file) { found = 1 }
    found && match($0, /kvm-sha256">[0-9a-f]+/) { print substr($0, RSTART + 12, RLENGTH - 12); exit }
  ' <<<"$page")
  pin oracle-9 "${file%.qcow2}" "$url" sha256 "$hash" checksum-only
}

update_rocky-9() {
  local arch base file
  arch=$(rpm_arch)
  base=https://dl.rockylinux.org/pub/rocky/9/images/$arch
  save "$base/CHECKSUM" sums
  save "$base/CHECKSUM.asc" sums.asc
  verify_gpg rocky-9.asc "$work/sums.asc" "$work/sums"
  file=$(newest "Rocky-9-GenericCloud-Base-9\.[0-9]+-[0-9.]+\.$arch\.qcow2" <"$work/sums")
  pin rocky-9 "$(sed -E "s/^Rocky-9-GenericCloud-Base-(.*)\.$arch\.qcow2$/\1/" <<<"$file")" \
    "$base/$file" sha256 "$(checksum_of "$work/sums" "$file")" signature
}

update_talos-1.14() {
  # vanilla factory schematic. Factory images are not covered by the release's
  # checksums, so this is the one image that has to be downloaded.
  local schematic=376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba
  local version url hash
  version=$(fetch 'https://api.github.com/repos/siderolabs/talos/releases?per_page=100' |
    jq -r '.[] | select(.prerelease | not) | .tag_name' | newest '^v1\.14\.[0-9]+$')
  version=${version#v}
  if [[ $(jq -r --arg system "$system" '."talos-1.14".systems[$system].version' "$catalog") == "$version" ]]; then
    echo "talos-1.14 ($system): $version"
    return
  fi
  url=https://factory.talos.dev/image/$schematic/v$version/nocloud-$(deb_arch).raw.xz
  # hash of the decompressed image, not of the .xz
  hash=$(curl -fsSL --retry 3 "$url" | xz -dc | sha256sum | cut -d ' ' -f 1)
  PROVISIONER=none pin talos-1.14 "$version" "$url" sha256 "$hash" none xz
}

update_ubuntu-24.04() {
  local mirror=https://cloud-images.ubuntu.com/releases/noble version base file
  file=ubuntu-24.04-server-cloudimg-$(deb_arch).img
  version=$(fetch "$mirror/" | newest 'release-[0-9]{8}')
  base=$mirror/$version
  save "$base/SHA256SUMS" sums
  save "$base/SHA256SUMS.gpg" sums.gpg
  verify_gpg ubuntu-cloud.asc "$work/sums.gpg" "$work/sums"
  pin ubuntu-24.04 "${version#release-}" "$base/$file" sha256 \
    "$(checksum_of "$work/sums" "$file")" signature
}

if [[ ! -f $catalog ]]; then
  echo "$catalog not found: run this from the repository root" >&2
  exit 1
fi

# one image and system run directly; anything else runs each of them as a
# separate process, so that one broken upstream does not stop the others
if [[ $# -eq 2 && $2 == *-linux ]]; then
  system=$2
  "update_$1"
  exit
fi

failed=()
for name in "${@:-${all[@]}}"; do
  for system in ${systems_of[$name]:-$all_systems}; do
    "$0" "$name" "$system" || failed+=("$name ($system)")
  done
done

if [[ ${#failed[@]} -gt 0 ]]; then
  printf 'failed: %s\n' "${failed[@]}" >&2
  exit 1
fi
