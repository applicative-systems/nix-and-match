#!/usr/bin/env nix-shell
#!nix-shell -i bash -p openssl openssh nix
# Test-only keys, committed so that the test needs no evaluation-time builds.
# Never use them outside of the test network. Regenerate from this directory:
#
#   ./generate.sh
set -euo pipefail

# CA that the guests trust, and a certificate for the hosts the `cache` node
# stands in for
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -days 36500 -subj "/CN=nix-and-match test CA" -keyout ca.key -out ca.pem
openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -subj "/CN=cache" -keyout server.key -out server.csr
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial \
  -days 36500 -out server.pem -extfile <(
    printf 'subjectAltName=%s\n' \
      "DNS:cache,DNS:artifacts.nixos.org,DNS:github.com,DNS:nixos.org,DNS:releases.nixos.org"
  )
# the CA only signs this one certificate
rm server.csr ca.srl ca.key

# binary cache signing key
nix --extra-experimental-features nix-command key generate-secret --key-name cache-1 >cache.secret
nix --extra-experimental-features nix-command key convert-secret-to-public <cache.secret >cache.public

# root's ssh key on the guests, to build on the `cache` node
rm -f builder builder.pub
ssh-keygen -q -t ed25519 -N "" -C "nix-and-match builder" -f builder
