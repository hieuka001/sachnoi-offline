// library.js — Tìm kiếm + sắp xếp thư viện: logic thuần, test được bằng Node.
// Không chạm DOM/IndexedDB — app.js gọi 2 hàm này trong renderLibrary.

/** Gấp dấu tiếng Việt để tìm không dấu cũng khớp ("dao duc" khớp "Đạo Đức"). */
export function foldLibraryText(s) {
  return String(s ?? "").normalize("NFD").replace(/[\u0300-\u036f]/g, "").replace(/đ/g, "d").replace(/Đ/g, "D").toLowerCase();
}

/**
 * Lọc sách theo tên hoặc tác giả (không dấu, không phân biệt hoa/thường).
 * @param {Array} books — meta sách {title, author}
 * @param {string} query — từ khoá; rỗng thì trả toàn bộ
 */
export function filterBooks(books, query) {
  const q = foldLibraryText((query ?? "").trim());
  if (!q) return [...books];
  return books.filter((b) =>
    foldLibraryText(b.title).includes(q) || foldLibraryText(b.author ?? "").includes(q));
}

/** Phần đã nghe của 1 cuốn (0..1); null khi chưa có tiến độ (xếp cuối khi sắp theo tiến độ). */
function progressFraction(pr) {
  if (!pr || !pr.totalSentences) return null;
  return Math.min(1, (pr.sentenceIndex + 1) / pr.totalSentences);
}

const byTitle = (a, b) =>
  String(a.title || "").localeCompare(String(b.title || ""), "vi", { sensitivity: "base" });

/**
 * Sắp xếp thư viện (trả mảng mới, không sửa mảng gốc).
 * @param {Array} books
 * @param {Map|Object} progressById — bookId -> {sentenceIndex, totalSentences}
 * @param {"recent"|"title"|"progress"} mode
 *  - recent: mới thêm trước (addedAt giảm dần)
 *  - title: tên A–Z (tiếng Việt)
 *  - progress: nghe nhiều trước; chưa nghe xếp cuối; hoà thì tên A–Z
 */
export function sortBooks(books, progressById, mode = "recent") {
  const list = [...books];
  const getPr = (id) => (progressById instanceof Map ? progressById.get(id) : progressById?.[id]);
  if (mode === "title") return list.sort(byTitle);
  if (mode === "progress") {
    return list.sort((a, b) => {
      const va = progressFraction(getPr(a.id)) ?? -1;
      const vb = progressFraction(getPr(b.id)) ?? -1;
      return vb - va || byTitle(a, b);
    });
  }
  return list.sort((a, b) => (b.addedAt || 0) - (a.addedAt || 0) || byTitle(a, b));
}
