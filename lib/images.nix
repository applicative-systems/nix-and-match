{ pkgs }:
let
  inherit (pkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;
in
# images.json is generated: use `nix run .#update-images`
lib.mapAttrs (
  name: entry:
  let
    pin = entry.systems.${system} or (throw "image ${name} is not available for ${system}");
  in
  {
    inherit (entry)
      format
      provisioner
      version
      verification
      ;
    image = pkgs.fetchurl (
      {
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
  }
) (lib.importJSON ./images.json)
