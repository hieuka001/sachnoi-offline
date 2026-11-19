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
// 3.3.0: 1 giọng hệ thống (Linh, mặc định) + đúng 10 giọng Supertonic 3
// (5 nữ F1–F5 + 5 nam M1–M5); gói supertonic-3-int8 phải available.
if ((m.voices || []).length !== 11) errors.push(`Danh sách giọng phải đúng 11 (1 hệ thống + 10 Supertonic): đang có ${(m.voices || []).length}`);
if ((m.voices || []).filter(v => v.engine === "system").length !== 1) errors.push("Phải có đúng 1 giọng engine 'system'");
if ((m.voices || []).filter(v => v.engine === "supertonic").length !== 10) errors.push("Phải có đúng 10 giọng engine 'supertonic'");
if (!(m.packs || []).some(p => p.id === "supertonic-3-int8" && p.status === "available")) errors.push("Thiếu gói supertonic-3-int8 (available)");
if (errors.length) { console.error("MANIFEST LỖI:\n- " + errors.join("\n- ")); process.exit(1); }
console.log(`Manifest OK: ${m.packs.length} gói, ${m.voices.length} giọng, version ${m.version}`);
