#!/usr/bin/env bash
# upload-core-release.sh — Đăng gói Core VieNeu int8 lên GitHub Releases.
# Nguồn file: thư mục TTSAssets đã kiểm chứng của Bút Nghiên (cùng bộ assets int8).
# Cách dùng:  ASSETS_DIR=~/workspace/butnghien-ios/ios/App/App/TTSAssets tools/upload-core-release.sh
# Yêu cầu: gh CLI đã đăng nhập hieuka001 và repo hieuka001/sachnoi-offline đã tồn tại.
set -euo pipefail
: "${ASSETS_DIR:?Cần ASSETS_DIR trỏ tới thư mục chứa 12 file assets VieNeu}"
TAG="core-vieneu-turbo-int8-v1"
REPO="hieuka001/sachnoi-offline"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export ASSETS_DIR REPO_ROOT

echo "Kiểm tra sha256 + size theo voices/voices.json..."
python3 - << 'PY'
import json, hashlib, pathlib, os
root = pathlib.Path(os.environ["ASSETS_DIR"])
manifest = json.loads((pathlib.Path(os.environ["REPO_ROOT"]) / "voices/voices.json").read_text(encoding="utf-8"))
pack = next(p for p in manifest["packs"] if p["id"] == "vieneu-turbo-int8")
bad = []
for f in pack["files"]:
    p = root / f["name"]
    if not p.exists():
        bad.append(f["name"] + " (thiếu)"); continue
    if hashlib.sha256(p.read_bytes()).hexdigest() != f["sha256"]:
        bad.append(f["name"] + " (sha256 lệch)")
    if p.stat().st_size != f["size"]:
        bad.append(f["name"] + " (size lệch)")
if bad:
    raise SystemExit("DỪNG — file không khớp manifest: " + ", ".join(bad))
print(f'{len(pack["files"])}/{len(pack["files"])} file khớp manifest.')
PY

gh release create "$TAG" --repo "$REPO" --title "VieNeu Core int8 v1" \
  --notes "Bộ đọc VieNeu v3 Turbo int8 (48kHz) cho app Sách Nói Offline: tải 1 lần, dùng 25 giọng, offline hoàn toàn." \
  || echo "Release đã tồn tại — chuyển sang upload bổ sung."
cd "$ASSETS_DIR"
for f in config.json heads.bin heads.json tokenizer.json sea_g2p.bin voices_v3_turbo.json \
         vieneu_prefill.onnx vieneu_decode_step.onnx vieneu_acoustic_cached.onnx \
         vieneu_backbone_shared.data moss_audio_tokenizer_decode_full.onnx \
         moss_audio_tokenizer_decode_shared.data; do
  gh release upload "$TAG" "$f" --repo "$REPO" --clobber
done
echo "Xong: https://github.com/$REPO/releases/tag/$TAG"
