{ pkgs }:
let
  inherit (pkgs) lib;
in
# images.json is generated: use `nix run .#update-images`
lib.mapAttrs (name: entry: {
  inherit (entry) format provisioner verification;

  # whether the image's kernel can mount virtiofs shares
  virtiofs = entry.virtiofs or true;

  # systems the image is published for
  systems = lib.attrNames entry.systems;

  # per system: `version` and the decompressed `image`
  pins = lib.mapAttrs (_: pin: {
    inherit (pin) version;
    image = pkgs.fetchurl (
      {
        # the hash already differs per system
        name = "${name}.${entry.format}";
        inherit (pin) url hash;
      }
      // lib.optionalAttrs (entry.compression or null == "xz") {
        downloadToTemp = true;
        nativeBuildInputs = [ pkgs.xz ];
        postFetch = ''
          xz -dc "$downloadedFile" > "$out"
        '';
      }
    );
  }) entry.systems;
}) (lib.importJSON ./images.json)
