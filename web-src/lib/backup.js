// backup.js — Sao lưu / khôi phục thư viện ra 1 file JSON (1.2.0).
// Vì sao cần: dữ liệu chỉ nằm trong máy, xoá app là mất hết sách + tiến độ +
// dấu trang + từ điển. Bản sao lưu gồm: thông tin sách, bản trích (chương/đoạn),
// tiến độ nghe, dấu trang, từ điển từng sách. KHÔNG gồm file gốc (EPUB/PDF) —
// sách khôi phục đọc/nghe bình thường từ bản trích, chỉ không trích lại được
// khi logic trích đổi bản (khi đó app vẫn dùng bản trích đã lưu).
// Hàm thuần, test được bằng node (tests/backup.test.js).

export const BACKUP_FORMAT = "sachnoi-backup";
export const BACKUP_VERSION = 1;

export function buildBackup({ books, progressList, bookmarksByBook = {}, dictsByBook = {}, exportedAt = Date.now() }) {
  const progressById = new Map((progressList || []).map((p) => [p.bookId, p]));
  const included = [];
  let skipped = 0;
  for (const meta of books || []) {
    const pr = progressById.get(meta.id);
    if (!pr?.extractedCache?.chapters?.length) { skipped++; continue; }
    included.push({
      meta,
      extracted: pr.extractedCache,
      progress: {
        sentenceIndex: pr.sentenceIndex || 0,
        totalSentences: pr.totalSentences || 0,
        chapterTitle: pr.chapterTitle || "",
        lastListenedAt: pr.lastListenedAt || 0,
      },
      bookmarks: bookmarksByBook[meta.id] || [],
      dict: dictsByBook[meta.id] || {},
    });
  }
  return {
    format: BACKUP_FORMAT, version: BACKUP_VERSION, exportedAt,
    app: "Sách Nói Offline", books: included, skipped,
  };
}

export function parseBackup(data) {
  let obj = data;
  if (typeof data === "string") {
    try { obj = JSON.parse(data); } catch { throw new Error("File sao lưu không phải JSON hợp lệ."); }
  }
  if (!obj || obj.format !== BACKUP_FORMAT) throw new Error("Đây không phải file sao lưu của Sách Nói Offline.");
  if ((obj.version || 0) > BACKUP_VERSION) throw new Error("File sao lưu mới hơn bản app này — hãy cập nhật app trước.");
  if (!Array.isArray(obj.books)) throw new Error("File sao lưu thiếu danh sách sách.");
  const books = [];
  for (const b of obj.books) {
    if (!b?.meta?.id || !b?.extracted?.chapters?.length) continue; // bỏ mục hỏng, giữ phần còn tốt
    books.push({
      meta: b.meta,
      extracted: b.extracted,
      progress: b.progress || { sentenceIndex: 0 },
      bookmarks: Array.isArray(b.bookmarks) ? b.bookmarks : [],
      dict: b.dict && typeof b.dict === "object" ? b.dict : {},
    });
  }
  if (!books.length) throw new Error("File sao lưu không có cuốn sách nào khôi phục được.");
  return { books, exportedAt: obj.exportedAt || 0 };
}
