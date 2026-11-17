// store.js — Lưu trữ local 100% bằng IndexedDB: sách, tiến độ, từ điển cá nhân.
// Không server, không tài khoản. Xoá app là mất dữ liệu (đúng bản chất offline).

const DB_NAME = "sachnoi-offline";
const DB_VERSION = 1;

function openDb() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, DB_VERSION);
    req.onupgradeneeded = () => {
      const db = req.result;
      db.createObjectStore("books", { keyPath: "id" });
      db.createObjectStore("blobs", { keyPath: "id" });
      db.createObjectStore("progress", { keyPath: "bookId" });
      db.createObjectStore("bookDict", { keyPath: "bookId" });
      db.createObjectStore("packs", { keyPath: "id" }); // chỉ dùng ở bản trình duyệt (dev)
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

async function tx(store, mode, fn) {
  const db = await openDb();
  return new Promise((resolve, reject) => {
    const t = db.transaction(store, mode);
    const request = fn(t.objectStore(store));
    if (request) {
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
    } else {
      t.oncomplete = () => resolve(true);
      t.onerror = () => reject(t.error);
    }
  });
}

export const store = {
  async addBook(meta, blob) {
    await tx("books", "readwrite", (s) => s.put(meta));
    await tx("blobs", "readwrite", (s) => s.put({ id: meta.id, blob }));
  },
  async updateBook(id, patch) {
    const prev = await tx("books", "readonly", (s) => s.get(id));
    if (prev) await tx("books", "readwrite", (s) => s.put({ ...prev, ...patch, id }));
  },
  async listBooks() {
    const all = await tx("books", "readonly", (s) => s.getAll());
    return (all || []).sort((a, b) => (b.addedAt || 0) - (a.addedAt || 0));
  },
  async getBlob(id) {
    const row = await tx("blobs", "readonly", (s) => s.get(id));
    return row?.blob ?? null;
  },
  async deleteBook(id) {
    await tx("books", "readwrite", (s) => s.delete(id));
    await tx("blobs", "readwrite", (s) => s.delete(id));
    await tx("progress", "readwrite", (s) => s.delete(id));
  },
  async getProgress(bookId) {
    return (await tx("progress", "readonly", (s) => s.get(bookId))) || null;
  },
  // MERGE với bản ghi cũ — không ghi đè trắng (bản 1.0.0 từng làm mất extractedCache
  // mỗi lần lưu vị trí nghe, khiến mở lại sách phải trích lại từ đầu).
  async setProgress(bookId, data) {
    const prev = (await tx("progress", "readonly", (s) => s.get(bookId))) || {};
    await tx("progress", "readwrite", (s) => s.put({ ...prev, bookId, ...data, updatedAt: Date.now() }));
  },
  async listProgress() {
    const all = await tx("progress", "readonly", (s) => s.getAll());
    return all || [];
  },
  async getBookDict(bookId) {
    const row = await tx("bookDict", "readonly", (s) => s.get(bookId));
    return row?.dict || {};
  },
  async setBookDict(bookId, dict) {
    await tx("bookDict", "readwrite", (s) => s.put({ bookId, dict }));
  },
};

export function newId() {
  return Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
}

export function formatBytes(n) {
  if (!n && n !== 0) return "?";
  if (n < 1024) return `${n} B`;
  if (n < 1024 ** 2) return `${(n / 1024).toFixed(1)} KB`;
  if (n < 1024 ** 3) return `${(n / 1024 ** 2).toFixed(1)} MB`;
  return `${(n / 1024 ** 3).toFixed(2)} GB`;
}
