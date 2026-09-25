{ pkgs }:
{
  ubuntu = {
    format = "qcow2";
    image = pkgs.fetchurl {
      url = "https://cloud-images.ubuntu.com/releases/noble/release-20260911/ubuntu-24.04-server-cloudimg-amd64.img";
      hash = "sha256-YSssDMG8QTpsuMOP1hF5TK8PK0NsUAE9izeU2xKtc1Q=";
    };
  };

  almalinux = {
    format = "qcow2";
    image = pkgs.fetchurl {
      url = "https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-9.8-20260810.x86_64.qcow2";
      hash = "sha256-a9q2N21G1C5CA6zjcz76/HxdN8fLRDpsx0dQCXAC10s=";
    };
  };

  # vanilla factory schematic; bump version and hash together (FOD reuse hides stale urls)
  talos = rec {
    version = "1.14.1";
    format = "raw";
    image =
      pkgs.runCommand "talos-nocloud-amd64.raw" { nativeBuildInputs = [ pkgs.xz ]; } ''
        xz -dc ${
          pkgs.fetchurl {
            url = "https://factory.talos.dev/image/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba/v${version}/nocloud-amd64.raw.xz";
            hash = "sha256-Mao4Dp3eKDRmZwAg796sX7h3WDgJQDjA32UPic/rfEA=";
          }
        } > $out
      '';
  };
}
