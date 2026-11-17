// extract.js — Lớp 1 (cấu trúc sách): trích EPUB / PDF / TXT thành chương + đoạn.
// EPUB: đọc theo spine (đúng thứ tự chương của sách). PDF: gom dòng theo toạ độ y,
// đánh dấu sách scan khi gần như không có text layer.

// Tăng số này mỗi khi logic trích thay đổi: sách đã lưu cache cũ sẽ được trích
// lại từ file gốc ở lần mở kế tiếp (xem openBook trong app.js).
export const EXTRACT_VERSION = 2;

export async function extractBook(file) {
  const name = file.name || "sach";
  const ext = name.split(".").pop().toLowerCase();
  if (ext === "epub") return extractEpub(file, name);
  if (ext === "pdf") return extractPdf(file, name);
  const text = await file.text();
  return { title: stripExt(name), author: "", chapters: splitPlainText(text), scanned: false, extractVersion: EXTRACT_VERSION };
}

// ---------- Nhận diện bìa / mục lục (chỉ dùng cho EPUB) ----------
// Nguyên tắc: thà giữ thừa còn hơn xoá nhầm chương thật. Heuristic chỉ áp cho
// vài mục đầu sách; dấu hiệu metadata (guide/nav/linear) thì chắc chắn hơn.
const TOC_TITLES = /^(mục lục|contents|table of contents|nội dung|mục lục sách)$/i;

export function isTocLikeChapter(paragraphs) {
  if (!paragraphs || paragraphs.length < 5) return false;
  let tocLike = 0;
  let totalLen = 0;
  for (const raw of paragraphs) {
    const line = String(raw).trim();
    totalLen += line.length;
    const short = line.length <= 90;
    const hasLeader = /\.{2,}\s*\d*\s*$/.test(line) || /…\s*\d+\s*$/.test(line);
    const endsWithPageNum = short && /\d{1,4}\s*$/.test(line) && /\D/.test(line);
    const numberedEntry = /^\s*(§\s*)?([IVXLCDM]{1,6}|\d{1,3})\s*[.)\s]/.test(line)
      || /^(phần|chương|mục|bài|quyển)\s+[\divxlcdm]+/i.test(line);
    if (short && (hasLeader || endsWithPageNum || numberedEntry)) tocLike++;
  }
  const avgLen = totalLen / paragraphs.length;
  return tocLike / paragraphs.length >= 0.6 && avgLen < 80;
}

export function isCoverLikeChapter(paragraphs) {
  if (!paragraphs || !paragraphs.length || paragraphs.length > 6) return false;
  const totalChars = paragraphs.reduce((s, x) => s + String(x).length, 0);
  return totalChars <= 220;
}

const stripExt = (n) => n.replace(/\.[^.]+$/, "");
const clean = (s) => s.replace(/\u00a0/g, " ").replace(/[ \t]+/g, " ").trim();

// ---------- EPUB ----------
async function extractEpub(file, name) {
  if (!window.JSZip) throw new Error("Thiếu thư viện đọc EPUB (jszip).");
  const zip = await window.JSZip.loadAsync(file);
  const container = await zip.file("META-INF/container.xml")?.async("text");
  if (!container) throw new Error("File EPUB không hợp lệ (thiếu container.xml).");
  const opfPath = new DOMParser().parseFromString(container, "text/xml")
    .querySelector("rootfile")?.getAttribute("full-path");
  if (!opfPath) throw new Error("File EPUB không hợp lệ (thiếu OPF).");
  const base = opfPath.includes("/") ? opfPath.slice(0, opfPath.lastIndexOf("/") + 1) : "";
  const opf = new DOMParser().parseFromString(await zip.file(opfPath).async("text"), "text/xml");
  const title = clean(opf.querySelector("metadata title")?.textContent || "") || stripExt(name);
  const author = clean(opf.querySelector("metadata creator")?.textContent || "");
  const manifest = {};
  const manifestProps = {};
  opf.querySelectorAll("manifest item").forEach((it) => {
    manifest[it.getAttribute("id")] = it.getAttribute("href");
    manifestProps[it.getAttribute("id")] = it.getAttribute("properties") || "";
  });
  // Dấu hiệu chắc chắn từ metadata: guide cover/toc (EPUB2) + file nav (EPUB3)
  const guideHrefs = new Set();
  opf.querySelectorAll("guide reference").forEach((r) => {
    const type = (r.getAttribute("type") || "").toLowerCase();
    if (type === "cover" || type === "toc") guideHrefs.add((r.getAttribute("href") || "").split("#")[0]);
  });
  const navHref = Object.keys(manifest).find((id) => /\bnav\b/.test(manifestProps[id])) ? manifest[Object.keys(manifest).find((id) => /\bnav\b/.test(manifestProps[id]))] : null;
  const chapters = [];
  const allChapters = []; // bản chưa lọc nội dung — dự phòng không lọc sạch cả sách
  const itemrefs = [...opf.querySelectorAll("spine itemref")];
  for (let spineIdx = 0; spineIdx < itemrefs.length; spineIdx++) {
    const itemref = itemrefs[spineIdx];
    const idref = itemref.getAttribute("idref");
    const href = manifest[idref];
    if (!href) continue;
    const hrefClean = href.split("#")[0];
    // Bỏ qua theo metadata: mục ẩn (linear=no), bìa/mục lục trong guide, file nav
    if (itemref.getAttribute("linear") === "no") continue;
    if (guideHrefs.has(hrefClean) || (navHref && hrefClean === navHref.split("#")[0])) continue;
    const entry = zip.file(base + decodeURIComponent(href)) || zip.file(href);
    if (!entry) continue;
    const html = await entry.async("text");
    const doc = new DOMParser().parseFromString(html, "text/html");
    doc.querySelectorAll("script, style").forEach((e) => e.remove());
    const heading = clean(doc.querySelector("h1, h2, h3")?.textContent || "");
    const paragraphs = [];
    doc.querySelectorAll("p, h1, h2, h3, h4, li, blockquote").forEach((el) => {
      const t = clean(el.textContent || "");
      if (t) paragraphs.push(t);
    });
    if (!paragraphs.length) {
      const t = clean(doc.body?.textContent || "");
      if (t) paragraphs.push(t);
    }
    if (!paragraphs.length) continue;
    const chapterTitle = heading || `Phần ${allChapters.length + 1}`;
    allChapters.push({ title: chapterTitle, paragraphs });
    // Bỏ qua theo nội dung: chương tên đúng là "Mục lục" (mọi vị trí), hoặc —
    // chỉ trong 3 mục đầu sách — trang bìa/thông tin xuất bản rất ngắn, hoặc
    // trang toàn dòng mục lục ngắn. Không bao giờ lọc sạch cả sách.
    if (TOC_TITLES.test(chapterTitle)) continue;
    if (spineIdx === 0 && isCoverLikeChapter(paragraphs)) continue;
    if (spineIdx < 3 && isTocLikeChapter(paragraphs)) continue;
    chapters.push({ title: chapterTitle, paragraphs });
  }
  const finalChapters = chapters.length ? chapters : allChapters;
  if (!finalChapters.length) throw new Error("Không trích được nội dung từ EPUB này.");
  return { title, author, chapters: finalChapters, scanned: false, extractVersion: EXTRACT_VERSION };
}

// ---------- PDF ----------
async function extractPdf(file, name) {
  const pdfjs = await import("../vendor/pdf.min.mjs");
  pdfjs.GlobalWorkerOptions.workerSrc = new URL("../vendor/pdf.worker.min.mjs", import.meta.url).href;
  const data = await file.arrayBuffer();
  const pdf = await pdfjs.getDocument({
    data,
    cMapUrl: new URL("../vendor/cmaps/", import.meta.url).href,
    cMapPacked: true,
    standardFontDataUrl: new URL("../vendor/standard_fonts/", import.meta.url).href,
  }).promise;
  const chapters = [];
  let totalChars = 0;
  for (let p = 1; p <= pdf.numPages; p++) {
    const page = await pdf.getPage(p);
    const content = await page.getTextContent();
    // Gom item thành dòng theo toạ độ y (sai số 2pt), giữ thứ tự trên-xuống, trái-phải.
    const lines = new Map();
    for (const item of content.items) {
      if (!item.str) continue;
      const y = Math.round(item.transform[5] / 2) * 2;
      if (!lines.has(y)) lines.set(y, []);
      lines.get(y).push({ x: item.transform[4], str: item.str });
    }
    let pageLines = [...lines.entries()]
      .sort((a, b) => b[0] - a[0])
      .map(([, items]) => items.sort((a, b) => a.x - b.x).map((i) => i.str).join(" ").replace(/\s+/g, " ").trim())
      .filter(Boolean);
    // Fallback: gom dòng ra rỗng nhưng trang vẫn có mảnh chữ -> ghép thô theo thứ tự gốc
    if (!pageLines.length && content.items.length) {
      const raw = content.items.map((i) => i.str || "").join(" ").replace(/\s+/g, " ").trim();
      if (raw) pageLines = [raw];
    }
    const text = pageLines.join("\n");
    totalChars += text.length;
    if (text) chapters.push({ title: `Trang ${p}`, paragraphs: [text] });
  }
  // Ít hơn ~30 ký tự/trang = sách scan (chỉ có ảnh, không lớp chữ).
  // Không ném lỗi nữa: vẫn nhận sách vào thư viện, gắn cờ scan và 1 chương giải thích —
  // người dùng biết rõ lý do thay vì một câu báo lỗi chung chung.
  const scanned = totalChars / pdf.numPages < 30;
  if (scanned) {
    return {
      title: stripExt(name), author: "", scanned: true, pages: pdf.numPages, totalChars, extractVersion: EXTRACT_VERSION,
      chapters: [{
        title: "Sách scan — chưa đọc được",
        paragraphs: [`Sách này có ${pdf.numPages} trang nhưng chỉ trích được ${totalChars} ký tự chữ. Đây là sách scan dạng ảnh, không có lớp chữ bên dưới. Bản hiện tại chưa có nhận dạng chữ từ ảnh (OCR) nên chưa đọc được sách này. Các sách PDF có lớp chữ và EPUB vẫn đọc bình thường.`],
      }],
    };
  }
  if (!chapters.length) throw new Error(`Không trích được chữ từ PDF này (${pdf.numPages} trang, 0 ký tự).`);
  return { title: stripExt(name), author: "", chapters, scanned, pages: pdf.numPages, extractVersion: EXTRACT_VERSION };
}

// ---------- TXT / MD ----------
function splitPlainText(text) {
  const chapters = [];
  let current = { title: "Phần 1", paragraphs: [] };
  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.trim();
    const heading = /^(chương|chapter|phần|mục)\s+[\divxlcdm]+/i.test(line) && line.length < 80;
    if (heading && current.paragraphs.length) {
      chapters.push(current);
      current = { title: line, paragraphs: [] };
    } else if (line) current.paragraphs.push(line);
  }
  if (current.paragraphs.length) chapters.push(current);
  return chapters.length ? chapters : [{ title: "Phần 1", paragraphs: [text.trim()] }];
}
