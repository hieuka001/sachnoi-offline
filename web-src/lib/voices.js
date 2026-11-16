// voices.js — Danh mục gói (core + giọng) từ voices.json.
// Nguồn: ưu tiên bản mới trên GitHub (khi có mạng), rơi về bản đóng kèm app khi offline.
// Tải trong app iOS đi qua BackgroundDownloader native (tải nền thật);
// trên trình duyệt chỉ tải thử vào bộ nhớ đệm để xem giao diện.

import { native, isNative } from "./player.js";
import { formatBytes } from "./store.js";

export const MANIFEST_REMOTE = "https://raw.githubusercontent.com/hieuka001/sachnoi-offline/main/voices/voices.json";
const LS_KEY = "sachnoi.installedPacks.web";

export async function loadManifest() {
  try {
    const res = await fetch(MANIFEST_REMOTE, { cache: "no-cache" });
    if (res.ok) return { manifest: await res.json(), source: "online" };
  } catch { /* offline -> dùng bản kèm app */ }
  const local = await fetch("voices.json").then((r) => r.json());
  return { manifest: local, source: "offline" };
}

export function webInstalled() {
  try { return JSON.parse(localStorage.getItem(LS_KEY) || "{}"); } catch { return {}; }
}
function setWebInstalled(id, info) {
  const all = webInstalled();
  if (info) all[id] = info; else delete all[id];
  localStorage.setItem(LS_KEY, JSON.stringify(all));
}

export async function installedPackIds() {
  const bridge = native();
  if (bridge?.listInstalledPacks) {
    try {
      const { packs } = await bridge.listInstalledPacks();
      return new Map(packs.map((p) => [p.id, p.bytes]));
    } catch { /* rơi xuống dưới */ }
  }
  return new Map(Object.entries(webInstalled()).map(([id, v]) => [id, v.bytes || 0]));
}

/** Tải 1 gói. onProgress(pct) — native báo qua sự kiện, web báo qua fetch reader. */
export async function downloadPack(pack, onProgress) {
  const bridge = native();
  const files = pack.files.map((f) => ({ url: f.url, name: f.name, size: f.size, sha256: f.sha256 }));
  if (bridge?.downloadPack && isNative()) {
    await bridge.downloadPack({ packId: pack.id, files });
    return new Promise((resolve, reject) => {
      const subs = [];
      const cleanup = () => subs.forEach((s) => s.remove?.());
      subs.push(bridge.addListener("packDownloadProgress", ({ packId, received, total }) => {
        if (packId === pack.id && total > 0) onProgress(Math.min(99, Math.round((received / total) * 100)));
      }));
      subs.push(bridge.addListener("packDownloadFinished", async ({ packId }) => {
        if (packId !== pack.id) return;
        cleanup();
        onProgress(100);
        // Kiểm toàn vẹn sau tải
        try {
          const { files: results } = await bridge.verifyPack({ packId: pack.id, files });
          const bad = Object.entries(results).filter(([, v]) => v !== "ok");
          if (bad.length) return reject(new Error("Gói tải về lỗi ở file: " + bad.map(([k]) => k).join(", ")));
        } catch { /* verify không khả dụng -> vẫn coi như xong */ }
        resolve(true);
      }));
      subs.push(bridge.addListener("packFileFinished", ({ packId, error }) => {
        if (packId === pack.id && error) { cleanup(); reject(new Error(error)); }
      }));
    });
  }
  // Trình duyệt (dev): tải tuần tự để xem tiến độ, lưu trạng thái giả lập
  let done = 0;
  const total = files.reduce((a, f) => a + (f.size || 0), 0) || 1;
  for (const f of files) {
    const res = await fetch(f.url);
    if (!res.ok) throw new Error(`Không tải được ${f.name} (HTTP ${res.status})`);
    await res.arrayBuffer();
    done += f.size || 0;
    onProgress(Math.round((done / total) * 100));
  }
  setWebInstalled(pack.id, { bytes: total, at: Date.now() });
  return true;
}

export async function deletePack(pack) {
  const bridge = native();
  if (bridge?.deletePack && isNative()) await bridge.deletePack({ packId: pack.id });
  else setWebInstalled(pack.id, null);
}

export { formatBytes };
