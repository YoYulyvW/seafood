#!/usr/bin/env bash
# 从 GitHub Release 拉最新 IPA + manifest，推到飞牛容器发布目录
# 用法: ./scripts/fetch-release.sh <github-repo> [release-tag]
set -euo pipefail

REPO="${1:?用法: fetch-release.sh owner/repo [tag]}"
TAG="${2:-seafood-latest}"
SHARE="/fnshare/seafood-inventory/data/release"
API="https://api.github.com/repos/$REPO/releases/tags/$TAG"

echo "==> 查询 $REPO $TAG"
JSON=$(curl -fsSL "$API")
IPA_URL=$(printf '%s' "$JSON" | python3 -c 'import sys,json;d=json.load(sys.stdin);print([a["browser_download_url"] for a in d["assets"] if a["name"].endswith(".ipa")][0])')
MANIFEST_URL=$(printf '%s' "$JSON" | python3 -c 'import sys,json;d=json.load(sys.stdin);print([a["browser_download_url"] for a in d["assets"] if a["name"]=="manifest.json"][0])')
IPA_NAME=$(basename "$IPA_URL")

mkdir -p "$SHARE"
echo "==> 下载 $IPA_NAME"
curl -fL --retry 5 --retry-all-errors --retry-delay 2 -o "$SHARE/$IPA_NAME" "$IPA_URL"
curl -fL --retry 5 --retry-all-errors --retry-delay 2 -o /tmp/manifest.json "$MANIFEST_URL"

echo "==> 重写 manifest 指向本机"
python3 - "$SHARE/$IPA_NAME" "$IPA_NAME" <<'PY'
import json, sys, hashlib, os
path, name = sys.argv[1], sys.argv[2]
m = json.load(open('/tmp/manifest.json'))
m['file'] = name
m['ipa_url'] = '/api/app/download/' + name
m['size'] = os.path.getsize(path)
h = hashlib.sha256()
with open(path, 'rb') as f:
    for chunk in iter(lambda: f.read(1 << 20), b''):
        h.update(chunk)
m['sha256'] = h.hexdigest()
json.dump(m, open(os.path.join(os.path.dirname(path), 'manifest.json'), 'w'), ensure_ascii=False, indent=2)
print('manifest ->', m['version'], 'b' + str(m['build']), m['size'], 'bytes')
PY

echo "==> 清理旧包（保留最近 3 个）"
ls -1t "$SHARE"/*.ipa 2>/dev/null | tail -n +4 | xargs -r rm -f

echo "==> 验证"
curl -s "http://192.168.1.100:8100/api/app/latest" | head -c 300; echo
