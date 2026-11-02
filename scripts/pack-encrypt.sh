#!/usr/bin/env bash
# Packs out/ into out/results.enc: [512-byte RSA-OAEP wrapped key][AES-256-CBC payload]. Public log: canary hash + size only.
set -uo pipefail
mkdir -p out
echo "$(date -u +%s)-$RANDOM ${GITHUB_RUN_ID:-local}" > out/canary.txt
CAN=$(sha256sum out/canary.txt | cut -d' ' -f1)
tar -czf results.tgz --exclude='out/assets' --exclude='out/results.enc' out || { echo "pack: fail (tar)"; exit 1; }
openssl rand -hex 32 > key.txt
openssl pkeyutl -encrypt -pubin -inkey keys/lab_results_public.pem -pkeyopt rsa_padding_mode:oaep -pkeyopt rsa_oaep_md:sha256 -in key.txt -out key.rsa || { echo "pack: fail (wrap)"; exit 1; }
openssl enc -aes-256-cbc -pbkdf2 -salt -pass file:key.txt -in results.tgz -out payload.enc || { echo "pack: fail (enc)"; exit 1; }
cat key.rsa payload.enc > out/results.enc
rm -f key.txt key.rsa payload.enc results.tgz
echo "pack: ok canary_sha256=$CAN bytes=$(wc -c < out/results.enc)"
