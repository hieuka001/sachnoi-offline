// check-manifest.mjs — Kiểm tra voices.json: cấu trúc, sha256 đúng định dạng,
// gói "available" phải có file + url thuộc repo của mình. Chạy trong CI.
import { readFileSync } from "node:fs";

const m = JSON.parse(readFileSync(new URL("../voices/voices.json", import.meta.url), "utf8"));
const errors = [];
if (!m.version) errors.push("Thiếu version");
const ids = new Set();
for (const p of m.packs || []) {
  if (ids.has(p.id)) errors.push(`Trùng pack id: ${p.id}`);
  ids.add(p.id);
  if (p.status === "available") {
    if (!p.files?.length) errors.push(`Pack ${p.id}: available nhưng không có file`);
    for (const f of p.files || []) {
      if (!/^[a-f0-9]{64}$/.test(f.sha256 || "")) errors.push(`Pack ${p.id}/${f.name}: sha256 không hợp lệ`);
      if (!f.url?.startsWith("https://github.com/hieuka001/sachnoi-offline/releases/")) errors.push(`Pack ${p.id}/${f.name}: url ngoài repo`);
      if (!(f.size > 0)) errors.push(`Pack ${p.id}/${f.name}: size không hợp lệ`);
    }
  }
}
// 2.0.0: engine Piper gắn sẵn chỉ có 1 giọng — tối thiểu 1 là đủ.
if ((m.voices || []).length < 1) errors.push(`Danh sách giọng trống`);
if (errors.length) { console.error("MANIFEST LỖI:\n- " + errors.join("\n- ")); process.exit(1); }
console.log(`Manifest OK: ${m.packs.length} gói, ${m.voices.length} giọng, version ${m.version}`);
