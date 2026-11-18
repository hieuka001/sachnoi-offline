// extract.js — Lớp 1 (cấu trúc sách): trích EPUB / PDF / TXT thành chương + đoạn.
// EPUB: đọc theo spine (đúng thứ tự chương của sách). PDF: gom dòng theo toạ độ y,
// đánh dấu sách scan khi gần như không có text layer.

// Tăng số này mỗi khi logic trích thay đổi: sách đã lưu cache cũ sẽ được trích
// lại từ file gốc ở lần mở kế tiếp (xem openBook trong app.js).
export const EXTRACT_VERSION = 3;

export async function extractBook(file, opts = {}) {
  const name = file.name || "sach";
  const ext = name.split(".").pop().toLowerCase();
  if (ext === "epub") return extractEpub(file, name);
  if (ext === "pdf") return extractPdf(file, name, opts);
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

// Mục lục dạng VĂN XUÔI CHẢY: nhiều EPUB (như Đạo Đức Kinh của Nguyễn Hiến Lê)
// dồn mọi mục lục vào 1-2 đoạn dài, không xuống dòng từng mục — bản 1.0.4 chỉ
// nhìn theo dòng nên trượt. Hàm này chẻ văn bản tại các mốc mục (số thứ tự, §,
// PHẦN/CHƯƠNG, chữ cái A. B.) rồi đo độ ngắn/mật độ của các mẩu.
export function isTocLikeText(paragraphs) {
  if (!paragraphs || !paragraphs.length) return false;
  const text = paragraphs.join(" ").replace(/\s+/g, " ").trim();
  if (/^mục\s*lục\s*[:.]/i.test(text)) return true; // mở đầu đúng chữ "MỤC LỤC:"
  if (text.length > 8000) return false;
  const segments = text
    .split(/(?=§)|(?=\bPHẦN\s+)|(?=\bCHƯƠNG\s+)|(?=\bMỤC\s+)|(?=\b\d{1,2}\.\s)|(?=\b[A-D]\.\s)/)
    .map((s) => s.trim())
    .filter((s) => s.length > 2);
  if (segments.length < 8) return false;
  const avgLen = segments.reduce((a, s) => a + s.length, 0) / segments.length;
  const shortRatio = segments.filter((s) => s.length <= 70).length / segments.length;
  return avgLen <= 60 && shortRatio >= 0.7;
}

// Tách đoạn tôn trọng cấu trúc dòng của EPUB: <br> = xuống dòng, chỉ lấy thẻ
// block "lá" (không chứa block khác) để không trùng nội dung. Bản cũ chỉ lấy
// <p> nên sách để chữ trong <div>/<br> bị dồn thành 1 đoạn khổng lồ.
function extractParagraphs(doc) {
  const body = doc.body;
  if (!body) return [];
  body.querySelectorAll("br").forEach((br) => br.replaceWith("\n"));
  const BLOCKS = "p, h1, h2, h3, h4, h5, h6, li, blockquote, div, section, article, td";
  const paras = [];
  body.querySelectorAll(BLOCKS).forEach((el) => {
    if (el.querySelector(BLOCKS)) return;
    const raw = (el.textContent || "").replace(/\u00a0/g, " ");
    for (const line of raw.split("\n")) {
      const c = clean(line);
      if (c) paras.push(c);
    }
  });
  if (!paras.length) {
    const t = clean(body.textContent || "");
    if (t) paras.push(t);
  }
  return paras;
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
    const paragraphs = extractParagraphs(doc);
    if (!paragraphs.length) continue;
    const chapterTitle = heading || `Phần ${allChapters.length + 1}`;
    allChapters.push({ title: chapterTitle, paragraphs });
    // Bỏ qua theo nội dung: chương tên đúng là "Mục lục" (mọi vị trí), hoặc —
    // chỉ trong 3 mục đầu sách — trang bìa/thông tin xuất bản rất ngắn, hoặc
    // trang toàn dòng mục lục ngắn. Không bao giờ lọc sạch cả sách.
    if (TOC_TITLES.test(chapterTitle)) continue;
    if (spineIdx === 0 && isCoverLikeChapter(paragraphs)) continue;
    if (spineIdx < 6 && isTocLikeChapter(paragraphs)) continue;
    if (spineIdx < 6 && isTocLikeText(paragraphs)) continue;
    chapters.push({ title: chapterTitle, paragraphs });
  }
  const finalChapters = chapters.length ? chapters : allChapters;
  if (!finalChapters.length) throw new Error("Không trích được nội dung từ EPUB này.");
  return { title, author, chapters: finalChapters, scanned: false, extractVersion: EXTRACT_VERSION };
}

// ---------- PDF ----------
// OCR từng trang PDF scan: vẽ trang ra canvas (pdf.js) rồi nhờ native nhận chữ.
// Gộp dòng thành đoạn: dòng không kết thúc bằng dấu câu + dòng sau viết thường
// thì nối tiếp, còn lại xuống đoạn mới.
async function ocrPdfPages(pdf, opts) {
  const chapters = [];
  for (let p = 1; p <= pdf.numPages; p++) {
    const page = await pdf.getPage(p);
    const viewport = page.getViewport({ scale: 2 });
    const canvas = document.createElement("canvas");
    canvas.width = Math.floor(viewport.width);
    canvas.height = Math.floor(viewport.height);
    const ctx = canvas.getContext("2d");
    await page.render({ canvasContext: ctx, viewport }).promise;
    const blob = await new Promise((res) => canvas.toBlob(res, "image/jpeg", 0.85));
    canvas.width = 0; canvas.height = 0; // giải phóng bộ nhớ ngay
    if (!blob) continue;
    const raw = (await opts.ocr(blob)) || "";
    const lines = raw.split("\n").map((x) => x.trim()).filter(Boolean);
    const paragraphs = [];
    for (const line of lines) {
      const prev = paragraphs[paragraphs.length - 1];
      if (prev && !/[.!?…:;”"]$/.test(prev) && /^[a-zà-ỹ]/.test(line)) {
        paragraphs[paragraphs.length - 1] = prev + " " + line;
      } else paragraphs.push(line);
    }
    if (opts.onProgress) opts.onProgress(Math.round((p / pdf.numPages) * 100), `Đang nhận dạng chữ (OCR) trang ${p}/${pdf.numPages}…`);
    if (paragraphs.length) chapters.push({ title: `Trang ${p}`, paragraphs });
  }
  return chapters;
}

async function extractPdf(file, name, opts = {}) {
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
  const scanned = totalChars / pdf.numPages < 30;
  if (scanned) {
    // 1.1.0: thử OCR offline (Apple Vision qua cầu native, chỉ app iOS 16+).
    // OCR chạy 1 lần lúc nhập sách, kết quả lưu như sách thường.
    let ocrNote = "";
    if (opts.ocr) {
      try {
        const ocrChapters = await ocrPdfPages(pdf, opts);
        const ocrChars = ocrChapters.reduce((a, c) => a + c.paragraphs.join("").length, 0);
        if (ocrChapters.length && ocrChars > 200) {
          return { title: stripExt(name), author: "", chapters: ocrChapters, scanned: true, ocr: true, pages: pdf.numPages, extractVersion: EXTRACT_VERSION };
        }
        ocrNote = " Đã thử nhận dạng chữ (OCR) nhưng chữ nhận được quá ít — có thể bản scan quá mờ.";
      } catch (e) {
        ocrNote = ` OCR chưa chạy được: ${e?.message || e}`;
      }
    }
    return {
      title: stripExt(name), author: "", scanned: true, pages: pdf.numPages, totalChars, extractVersion: EXTRACT_VERSION,
      chapters: [{
        title: "Sách scan — chưa đọc được",
        paragraphs: [`Sách này có ${pdf.numPages} trang nhưng chỉ trích được ${totalChars} ký tự chữ. Đây là sách scan dạng ảnh, không có lớp chữ bên dưới.${ocrNote} Tính năng nhận dạng chữ (OCR) chạy trong app iOS 16 trở lên; sách PDF có lớp chữ và EPUB vẫn đọc bình thường.`],
      }],
    };
  }
  if (!chapters.length) throw new Error(`Không trích được chữ từ PDF này (${pdf.numPages} trang, 0 ký tự).`);
  // Lọc bìa + mục lục ở các trang đầu (dùng chung bộ lọc với EPUB, 1.1.0).
  const pageLines = (ch) => ch.paragraphs.flatMap((x) => x.split("\n")).map((x) => clean(x)).filter(Boolean);
  let kept = chapters.filter((ch, i) => {
    if (i === 0 && isCoverLikeChapter(pageLines(ch))) return false;
    if (i < 6 && (isTocLikeChapter(pageLines(ch)) || isTocLikeText(pageLines(ch)))) return false;
    return true;
  });
  if (!kept.length) kept = chapters;
  return { title: stripExt(name), author: "", chapters: kept, scanned, pages: pdf.numPages, extractVersion: EXTRACT_VERSION };
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
