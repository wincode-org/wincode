#!/usr/bin/env bash
# Spike C: the distribution key, made and backed up before any certificate request. Nothing here contacts Apple.
#   dist-key.sh <key-dir> <backup-dir>
# Makes an RSA 2048 key (dist.key) and its certificate signing request (dist.csr) in <key-dir>, writes a
# passphrase-encrypted copy of the key to <backup-dir>/dist.key.enc.pem, then checks that the copy decrypts to
# the same key. openssl asks for the passphrase on the terminal and doesn't echo it; nothing stores it.
# Never overwrites: a step whose file exists is skipped, so running it again repeats only the restore check.
set -euo pipefail
[ $# -eq 2 ] || { echo "usage: dist-key.sh <key-dir> <backup-dir>" >&2; exit 2; }
KEY=$1/dist.key CSR=$1/dist.csr BACKUP=$2/dist.key.enc.pem
[ -t 0 ] || { echo "run this in a terminal: openssl asks for the backup passphrase" >&2; exit 1; }
umask 077
mkdir -p "$1" "$2"

if [ ! -e "$KEY" ]; then
  [ ! -e "$CSR" ] || { echo "$CSR exists without its key; not overwriting it" >&2; exit 1; }
  openssl genpkey -quiet -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$KEY"
fi
# Apple writes the certificate's subject itself, so the name in the request doesn't matter.
[ -e "$CSR" ] || openssl req -new -sha256 -key "$KEY" -subj "/CN=winCode spike C" -out "$CSR"
if [ ! -e "$BACKUP" ]; then
  echo "Backup passphrase (asked twice). Keep it in a password manager, not on this PC."
  openssl pkcs8 -topk8 -v2 aes-256-cbc -v2prf hmacWithSHA256 -iter 600000 -in "$KEY" -out "$BACKUP"
fi
echo "Restore check: type the backup passphrase once more."
if openssl pkey -in "$BACKUP" | cmp -s - "$KEY"; then
  echo "restore check OK: $BACKUP decrypts to $KEY"
else
  echo "restore check FAILED: run again to repeat the check; if the passphrase is lost, delete only $BACKUP and run again" >&2
  exit 1
fi
