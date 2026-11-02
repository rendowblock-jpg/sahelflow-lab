#!/usr/bin/env bash
# usage: fetch-release.sh [tag]   (empty = latest). Public log: only "ok"/"fail".
set -euo pipefail
TAG="${1:-}"
mkdir -p out/assets
API="https://api.github.com/repos/rendowblock-jpg/sahelflow_v2/releases"
if [ -z "$TAG" ]; then URL="$API/latest"; else URL="$API/tags/$TAG"; fi
AUTH=(); [ -n "${GH_TOKEN:-}" ] && AUTH=(-H "Authorization: Bearer ${GH_TOKEN}")
ok=0
for i in 1 2 3; do
  if curl -fsSL "${AUTH[@]}" -H "Accept: application/vnd.github+json" "$URL" -o out/release-api.json; then ok=1; break; fi
  sleep 5
done
[ "$ok" = 1 ] || { echo "fetch-release: fail (api)"; exit 1; }
node -e '
const fs=require("fs");const r=JSON.parse(fs.readFileSync("out/release-api.json","utf8"));
const pick=(re)=>r.assets.find(a=>re.test(a.name));
const msi=pick(/\.msi$/), exe=pick(/^SahelFlow_.*-setup\.exe$/), lj=pick(/^latest\.json$/);
const o={tag:r.tag_name,published:r.published_at,msi,exe,latest:lj};
fs.writeFileSync("out/assets/plan.txt",[o.msi&&o.msi.browser_download_url,o.latest&&o.latest.browser_download_url].filter(Boolean).join("\n"));
'
while read -r u; do
  [ -n "$u" ] || continue
  f="out/assets/$(basename "$u")"
  for i in 1 2 3; do curl -fsSL "${AUTH[@]}" -L "$u" -o "$f" && break || sleep 5; done
done < out/assets/plan.txt
( cd out/assets && sha256sum * ) > out/assets-sha256.txt 2>/dev/null || true
ls out/assets/*.msi >/dev/null 2>&1 || { echo "fetch-release: fail (no msi)"; exit 1; }
echo "fetch-release: ok"
