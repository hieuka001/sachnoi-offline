// playbackChunks.js — Chẻ câu thành ĐOẠN PHÁT ngắn cho bộ tổng hợp (1.8.1).
//
// Lỗi nghiêm trọng người dùng báo 2026-11-18: sách văn xuôi (Đạo Đức Kinh chú
// giải) có câu dài 250–350 ký tự; bộ phát native tổng hợp TOÀN BỘ câu xong mới
// phát nên mỗi câu dài là một khoảng im lặng chờ rất lâu ("quét 1 đoạn dài mới
// đọc"). Sửa cấu trúc: chẻ mỗi câu thành đoạn ngắn tại ranh giới mệnh đề
// (dấu phẩy/chấm phẩy/hai chấm), đoạn vẫn quá dài thì cắt tại khoảng trắng.
// Bộ phát chỉ phải tổng hợp 1 đoạn là phát ngay, các đoạn sau được prefetch
// trong lúc phát. Highlight/tiến độ/dấu trang vẫn tính theo CÂU — file này
// giữ ánh xạ đoạn -> câu.
//
// 1.9.4: đoạn nới từ 110 lên 180 ký tự — mỗi lần gọi engine tốn một lượt
// prefill cố định, đoạn dài hơn thì chi phí đó chia cho nhiều âm thanh hơn,
// tổng hợp theo kịp phát tốt hơn (máy thật 1.9.3 vẫn ngắt quãng từng đoạn).
//
// Cờ trên mỗi item gửi xuống native:
//   t: văn bản đoạn (đã chuẩn hoá để đọc)
//   c: tên chương
//   p: đoạn cuối của đoạn văn (nghỉ dài khi hết đoạn)
//   k: còn đoạn tiếp của CÙNG câu theo sau (ranh giới tại dấu câu giữa câu)

export const PLAYBACK_MAX_CHARS = 180;

export function chunkText(text, max = PLAYBACK_MAX_CHARS) {
  const t = String(text || "").trim();
  if (!t) return [];
  if (t.length <= max) return [t];
  // 1) Tách tại ranh giới mệnh đề (giữ dấu câu ở phần trước). "1,5kg" không có
  //    khoảng trắng sau phẩy nên không bị cắt nhầm.
  const parts = t.split(/(?<=[,;:])\s+/).filter(Boolean);
  // 2) Mảnh nào vẫn dài hơn max thì cắt tại khoảng trắng gần nhất <= max.
  const pieces = [];
  for (const part of parts) {
    let rest = part;
    while (rest.length > max) {
      let cut = rest.lastIndexOf(" ", max);
      if (cut < max * 0.5) cut = max; // không có khoảng trắng hợp lý: cắt cứng
      pieces.push(rest.slice(0, cut).trim());
      rest = rest.slice(cut).trim();
    }
    if (rest) pieces.push(rest);
  }
  // 3) Gói các mảnh lại cho đỡ vụn (mỗi đoạn <= max ký tự).
  const chunks = [];
  for (const piece of pieces) {
    const last = chunks[chunks.length - 1];
    if (last && (last + " " + piece).length <= max) chunks[chunks.length - 1] = last + " " + piece;
    else chunks.push(piece);
  }
  // 4) Đuôi vụn < 25 ký tự: gộp vào đoạn trước (được vượt max một chút) để
  //    tránh một lần tổng hợp riêng cho vài chữ cuối câu.
  if (chunks.length > 1) {
    const last = chunks[chunks.length - 1];
    if (last.length < 25 && (chunks[chunks.length - 2] + " " + last).length <= max + 30) {
      chunks[chunks.length - 2] += " " + last;
      chunks.pop();
    }
  }
  return chunks.filter(Boolean);
}

export function buildPlaybackItems(sentences) {
  const items = [];
  const itemSentence = [];
  const sentenceFirstItem = [];
  (sentences || []).forEach((s, si) => {
    sentenceFirstItem.push(items.length);
    const chunks = chunkText(s.spoken);
    chunks.forEach((c, ci) => {
      items.push({
        t: c,
        c: s.chapterTitle || "",
        p: !!s.paraEnd && ci === chunks.length - 1,
        k: ci < chunks.length - 1 ? 1 : 0,
      });
      itemSentence.push(si);
    });
  });
  return { items, itemSentence, sentenceFirstItem };
}
