// nowPlaying.js — Logic thuần cho màn hình "Đang nghe" toàn màn hình (1.8.0):
// bìa lớn + tên sách/chương lớn + câu đang đọc + thanh kéo tiến độ.
// Toàn bộ hàm thuần (không chạm DOM) để test bằng node:test.
export function coverLetter(title) {
  const t = String(title || "").trim();
  return t ? t.charAt(0).toUpperCase() : "?";
}

export function formatProgress(index, total, chapterTitle) {
  if (!total || total <= 0) return "Chưa có câu nào";
  const cur = Math.min(Math.max(index, 0), total - 1) + 1;
  const base = `Câu ${cur} / ${total}`;
  return chapterTitle ? `${base} · ${chapterTitle}` : base;
}

export function progressPercent(index, total) {
  if (!total || total <= 0) return 0;
  return Math.min(100, Math.round(((Math.min(Math.max(index, 0), total - 1) + 1) / total) * 100));
}

/** Kẹp chỉ số câu cho thanh kéo: ngoài khoảng thì về biên gần nhất. */
export function clampSeekIndex(value, total) {
  if (!total || total <= 0) return 0;
  const v = Number.isFinite(value) ? Math.trunc(value) : 0;
  return Math.min(Math.max(v, 0), total - 1);
}

/** Gom mọi dữ liệu hiển thị của màn hình Đang nghe từ trạng thái player. */
export function nowPlayingInfo({ title, author, chapterTitle, sentence, index, total }) {
  const t = total || 0;
  return {
    title: title || "—",
    author: author || "",
    chapterTitle: chapterTitle || "",
    sentence: sentence || "—",
    progressText: formatProgress(index, t, chapterTitle),
    percent: progressPercent(index, t),
    seekMax: Math.max(0, t - 1),
    seekValue: clampSeekIndex(index, t),
    coverLetter: coverLetter(title),
  };
}
