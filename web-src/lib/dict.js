// dict.js — Từ điển phát âm DÙNG CHUNG mọi sách (1.2.0).
// Trước đây mỗi cuốn một từ điển riêng: sửa cách đọc "Đạo Đức" ở sách này thì
// sách khác vẫn đọc sai. Nay có lớp chung lưu ở localStorage; từ điển riêng
// của sách (nếu có) được ưu tiên hơn khi trùng từ.

export const GLOBAL_DICT_KEY = "sachnoi.globalDict";

export function mergeDicts(globalDict, bookDict) {
  return { ...(globalDict || {}), ...(bookDict || {}) };
}

export function loadGlobalDict() {
  try {
    const d = JSON.parse(localStorage.getItem(GLOBAL_DICT_KEY) || "{}");
    return d && typeof d === "object" ? d : {};
  } catch { return {}; }
}

export function saveGlobalDict(dict) {
  try { localStorage.setItem(GLOBAL_DICT_KEY, JSON.stringify(dict || {})); } catch {}
}
