import { test } from "node:test";
import assert from "node:assert/strict";
import { numberToVietnamese, splitSentences, chunkSentences, prepareForSpeech, normalizeForSpeech } from "../src/text-engine/index.js";

test("số: bảng biến âm cốt lõi", () => {
  const cases = {
    0: "không", 5: "năm", 10: "mười", 11: "mười một", 15: "mười lăm", 21: "hai mươi mốt",
    24: "hai mươi tư", 25: "hai mươi lăm", 55: "năm mươi lăm", 100: "một trăm",
    101: "một trăm lẻ một", 105: "một trăm lẻ năm", 110: "một trăm mười", 115: "một trăm mười lăm",
    1000: "một nghìn", 1005: "một nghìn không trăm lẻ năm", 2023: "hai nghìn không trăm hai mươi ba",
    1000000: "một triệu", 1000000000: "một tỷ", 44000: "bốn mươi tư nghìn",
  };
  for (const [n, w] of Object.entries(cases)) assert.equal(numberToVietnamese(n), w, `số ${n}`);
});

test("chia câu: không cắt ở PGS.TS. và số thập phân", () => {
  const s = splitSentences("PGS.TS. Nguyễn Văn A đến lúc 15h30. Ông khám cho 3 bệnh nhân. Điểm đạt 8.5 điểm.");
  assert.equal(s.length, 3);
  assert.ok(s[0].startsWith("PGS.TS."));
});

test("chia câu: hội thoại và ba chấm", () => {
  const s = splitSentences("Anh nói... rồi bỏ đi. Cô ấy khóc. Sao vậy?");
  assert.equal(s.length, 3);
});

test("chunk: không vượt quá 180 ký tự, không mất chữ", () => {
  const { chunks, sentences } = prepareForSpeech("Câu một ngắn. " + "Đây là một câu rất dài, ".repeat(12) + "kết thúc ở đây. Câu cuối cùng.");
  assert.ok(chunks.every((c) => c.length <= 180));
  assert.ok(sentences.length >= 3);
});

test("pipeline: câu mẫu tích hợp", () => {
  const { sentences } = prepareForSpeech("Ngày 25/12/2023, BS. An đo huyết áp 120/80 mmHg cho bệnh nhân.");
  assert.equal(sentences.length, 1);
  assert.match(sentences[0].spoken, /hai mươi lăm tháng mười hai/);
  assert.match(sentences[0].spoken, /mi li mét thủy ngân/);
});

test("chữ IN HOA: đọc thành từ, không đánh vần, không nuốt vào số La Mã", () => {
  const cases = {
    "MỤC LỤC": "mục lục",
    "DO AI VIẾT?": "do ai viết?",
    "VŨ TRỤ": "vũ trụ",
    "ĐỜI SỐNG VÀ TÁC PHẨM": "đời sống và tác phẩm",
    "BẢN LÃO TỬ LƯU HÀNH NGÀY NAY": "bản lão tử lưu hành ngày nay",
  };
  for (const [input, expected] of Object.entries(cases)) {
    assert.equal(normalizeForSpeech(input), expected, input);
  }
});

test("số La Mã đúng ngữ cảnh, § đọc là mục", () => {
  assert.equal(normalizeForSpeech("Thế kỷ XVI"), "thế kỷ mười sáu");
  assert.equal(normalizeForSpeech("Chương III"), "chương ba");
  assert.equal(normalizeForSpeech("§II. TÍNH CÁCH"), "mục hai. tính cách");
  assert.equal(normalizeForSpeech("PHẦN I"), "phần một");
});

test("viết tắt nước ngoài quen thuộc vẫn đánh vần", () => {
  assert.match(normalizeForSpeech("FBI mở hồ sơ"), /ép bi ai/);
});
