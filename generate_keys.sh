#!/bin/bash

PRIVFILE="privkeys.txt"
PUBFILE="pubkeys.txt"

# Remove files if they exist
rm -f "$PRIVFILE" "$PUBFILE"

# Generate 32 private keys, save to PRIVFILE
for i in $(seq 1 32); do
  wg genkey >> "$PRIVFILE"
done

# For each private key generate the public key and save to PUBFILE
while IFS= read -r privkey; do
  echo "$privkey" | wg pubkey >> "$PUBFILE"
done < "$PRIVFILE"

echo "Generated 32 private keys in $PRIVFILE"
echo "Generated corresponding public keys in $PUBFILE"
