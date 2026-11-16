// extract.js — Lớp 1 (cấu trúc sách): trích EPUB / PDF / TXT thành chương + đoạn.
// EPUB: đọc theo spine (đúng thứ tự chương của sách). PDF: gom dòng theo toạ độ y,
// đánh dấu sách scan khi gần như không có text layer.

export async function extractBook(file) {
  const name = file.name || "sach";
  const ext = name.split(".").pop().toLowerCase();
  if (ext === "epub") return extractEpub(file, name);
  if (ext === "pdf") return extractPdf(file, name);
  const text = await file.text();
  return { title: stripExt(name), author: "", chapters: splitPlainText(text), scanned: false };
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
  opf.querySelectorAll("manifest item").forEach((it) => { manifest[it.getAttribute("id")] = it.getAttribute("href"); });
  const chapters = [];
  for (const itemref of opf.querySelectorAll("spine itemref")) {
    const href = manifest[itemref.getAttribute("idref")];
    if (!href) continue;
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
    if (paragraphs.length) chapters.push({ title: heading || `Phần ${chapters.length + 1}`, paragraphs });
  }
  if (!chapters.length) throw new Error("Không trích được nội dung từ EPUB này.");
  return { title, author, chapters, scanned: false };
}

// ---------- PDF ----------
async function extractPdf(file, name) {
  const pdfjs = await import("../vendor/pdf.min.mjs");
  pdfjs.GlobalWorkerOptions.workerSrc = new URL("../vendor/pdf.worker.min.mjs", import.meta.url).href;
  const data = await file.arrayBuffer();
  const pdf = await pdfjs.getDocument({ data }).promise;
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
    const pageLines = [...lines.entries()]
      .sort((a, b) => b[0] - a[0])
      .map(([, items]) => items.sort((a, b) => a.x - b.x).map((i) => i.str).join(" ").replace(/\s+/g, " ").trim())
      .filter(Boolean);
    const text = pageLines.join("\n");
    totalChars += text.length;
    if (text) chapters.push({ title: `Trang ${p}`, paragraphs: [text] });
  }
  if (!chapters.length) throw new Error("Không trích được chữ từ PDF này.");
  // Ít hơn ~30 ký tự/trang = gần như chắc chắn là sách scan
  const scanned = totalChars / pdf.numPages < 30;
  return { title: stripExt(name), author: "", chapters, scanned, pages: pdf.numPages };
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
