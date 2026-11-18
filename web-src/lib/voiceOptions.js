// voiceOptions.js — Dựng HTML <option> cho ô chọn giọng, dùng chung cho cả
// thanh phát (voiceSelect) lẫn sheet Tuỳ chỉnh (voiceSelectSheet).
// Thuần JS, không chạm DOM, để test được trực tiếp.
// 1.9.3 (P0-A): trước đây chuỗi options chỉ được dựng trong renderVoices()
// (chỉ chạy khi mở tab Giọng), nên mở app rồi vào thẳng sheet Tuỳ chỉnh thì
// cả 2 select đều trống -> iOS hiện "No Options". Giờ app.js điền options
// ngay lúc khởi động bằng hàm này, renderVoices() dùng chung.
const ESC = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };

export function escapeVoiceHtml(s) {
  return String(s ?? "").replace(/[&<>"']/g, (c) => ESC[c]);
}

/** voices: [{ id, name }] từ manifest. Luôn có option mặc định đầu tiên. */
export function buildVoiceOptions(voices) {
  const items = Array.isArray(voices) ? voices : [];
  return `<option value="default">Giọng mặc định</option>` +
    items.map((v) => `<option value="${escapeVoiceHtml(v.id)}">${escapeVoiceHtml(v.name)}</option>`).join("");
}
