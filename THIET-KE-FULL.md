# THIẾT KẾ BẢN FULL — App Đọc Sách Offline Tiếng Việt Cao Cấp Nhất

Ngày: 2026-11-16 · Trạng thái: THIẾT KẾ CHỐT ĐỂ BẮT ĐẦU CODE
Nguyên tắc xuyên suốt: **Tiếng Việt là trung tâm · Đọc đúng quan trọng hơn đọc nhanh ·
Offline tuyệt đối · App nhẹ, giọng tải theo nhu cầu · Mọi khẳng định đều có test**

Tên tạm: **Sách Nói Offline Pro** (anh đặt tên cuối sau, không ảnh hưởng code)

---

## PHẦN A — TỐI ĐA HOÁ GIỌNG NÓI

### A1. Hệ engine 3 cấp (tất cả đều tải từ GitHub Releases của anh, không server khác)

| Cấp | Engine | Gói tải | Chất lượng | Dùng khi |
|---|---|---|---|---|
| **MAX** | VieNeu v3 Turbo **fp32** 48kHz | Core ~530MB + codec | Cao nhất VieNeu công khai, chi tiết nhất | Máy mạnh, nghe sách dài, ưu tiên hay nhất |
| **CHUẨN (mặc định khuyên dùng)** | VieNeu v3 Turbo **int8** 48kHz | Core ~327MB (backbone int8 ~166MB + codec ~86MB + heads) | Gần MAX, nhanh hơn ~1,6 lần, nhẹ hơn ~4 lần phần backbone | Hầu hết người dùng |
| **NHẸ** | 1) VieNeu v3 Nano 24kHz (48M tham số, nhanh hơn Turbo ~3 lần) 2) Piper/VITS từng giọng độc lập 16–63MB/giọng | Nano: core nhỏ + 11 giọng · Piper: không core, tải giọng nào có giọng đó | Khá, đủ nghe truyện | Máy yếu / muốn nghe ngay / ít dung lượng |

- App mới cài: **20–25MB**, chưa có engine nào — người dùng chọn cấp ở lần mở đầu tiên, app ghi rõ dung lượng + thời gian tải ước tính + chất lượng trước khi bấm.
- Sau khi có Core Turbo: **25 giọng preset có sẵn gần như miễn phí** (mỗi giọng <1MB tham số), bấm "Tải giọng" là kích hoạt + đọc thử 1 câu ngay (đúng mô hình anh đã chốt ở Bút Nghiên đợt 31: tải giọng = dùng được ngay, không tải nội dung, không lưu audio đọc sẵn).

### A2. Danh mục giọng VieNeu v3 Turbo — đủ 25 giọng, 3 miền

- **Editors' Picks (10 giọng ổn định, tự nhiên nhất — app gắn sao, xếp đầu):**
  Minh Quân Pro (mặc định), Adam bựa, Trúc Ly, Anh Khôi, Mai Anh, + 5 picks còn lại theo `list_preset_voices()`
- **Miền Bắc:** Minh Quân, Phạm Tuyên, Anh Khôi, Mai Anh, Minh Đức, Xuân Vĩnh, Thanh Bình, Ngọc Linh, Đoan Trang, Quỳnh Anh, Mạnh Dũng
- **Miền Trung (chỉ có 2 — điểm yếu phải nói thật):** Quang Sơn (nam), Ngọc Trân (nữ).
  Biện pháp bù: (1) gắn nhãn rõ "giọng Trung hiện có 2 giọng", (2) để sẵn slot
  "Giọng Trung bổ sung" trong manifest — khi có voice pack mới là app tự thấy,
  (3) tính năng clone giọng (A5) cho phép tự tạo giọng Trung từ người thật.
- **Miền Nam:** Adam, Thái Sơn, Thục Đoan, Minh Triết, Mỹ Duyên, Đức Trí, Kim Thanh, Thuỳ Dung
- Mỗi giọng có metadata đầy đủ trong `voices.json`: vùng miền, giới tính, tính cách
  (tự nhiên / tin tức / đọc truyện), tốc độ gốc, độ ổn định (điểm test ở Phần C),
  dung lượng, SHA-256, 3 file MP3 nghe thử (đọc tin, đọc truyện, đọc số liệu).

### A3. Phong cách đọc & cảm xúc
- Mỗi giọng hỗ trợ các style: `tu_nhien` (tự nhiên), `tin_tuc` (tin tức), `doc_truyen` (đọc truyện) — app cho chọn style riêng với giọng, và tự gợi ý: sách truyện → doc_truyen, sách kiến thức/báo → tin_tuc.
- **Emotion cues (thử nghiệm, tắt mặc định):** VieNeu hiểu thẻ `[cười]`, `[thở dài]`, `[hắng giọng]` ngay trong text. App có bộ nhận diện hội thoại tuỳ chọn: tiếng cười viết thành chữ ("ha ha", "hì hì") trong đoạn hội thoại có thể gắn cue — chỉ bật khi người dùng chủ động chọn "Đọc diễn cảm", mặc định KHÔNG tự ý thêm để tránh đọc sai ý tác giả.
- Tuỳ chỉnh sâu cho từng giọng (lưu riêng từng giọng): tốc độ 0.75–2.0x, độ nghỉ giữa câu / giữa đoạn / giữa chương (hệ số nhân), bật/tắt đọc tiêu đề chương, bật/tắt đọc số trang.

### A4. Xử lý âm thanh sau tổng hợp (phần hay bị bỏ qua, bản FULL làm đủ)
- Chuẩn hoá âm lượng từng câu về cùng mức (tránh câu to câu nhỏ), cắt silence đầu/cuối câu, crossfade 10ms chống "tách" khi nối câu.
- Phát dạng stream PCM trong bộ nhớ + prefetch 2 câu tiếp theo: bấm nghe là phát, không chờ tổng hợp cả chương, không lưu file audio xuống đĩa (đúng chủ trương đợt 31).
- Đầu ra giữ nguyên 48kHz của Turbo; khi xuất qua Bluetooth/tai nghe vẫn giữ chất lượng, hỗ trợ phát nền + khoá màn hình + nút tai nghe (play/pause/next/prev) + ngắt đúng cách khi có cuộc gọi/báo thức rồi tự phát tiếp.

### A5. Giọng cá nhân (clone) — gói tuỳ chọn, riêng tư tuyệt đối
- VieNeu clone từ **đoạn mẫu sạch 3–8 giây** (dài hơn không tốt hơn — engine chỉ dùng phần đầu).
- Luồng: người dùng ghi âm / chọn file mẫu ngay trong app → tạo voice pack **chỉ lưu trên máy**, không upload đi đâu (offline + riêng tư), đặt tên tuỳ ý, xuất hiện trong danh sách giọng như giọng preset.
- Bắt buộc có màn hình xác nhận "đây là giọng của tôi / được người sở hữu đồng ý" trước khi tạo. Giọng clone không bao giờ được đưa lên GitHub Releases trừ khi chính anh chủ động xuất file.

### A6. Giọng nhẹ Piper/VITS tiếng Việt
- Có sẵn trong manifest: `vi_VN-vais1000-medium` (61MB), bản low (~16MB) cho máy yếu, VIVOS voice.
- Để sẵn pipeline đóng gói giọng VITS tiếng Việt mới (train/finetune từ dataset có giấy phép rõ ràng) thành file `.onnx + .onnx.json` chuẩn Piper — thêm giọng mới chỉ là thêm 1 asset + 1 dòng manifest, không phải sửa app. **Mỗi giọng bắt buộc kiểm tra license trước khi đưa lên Releases** (nhiều giọng Piper chỉ cho dùng phi thương mại).

---

## PHẦN B — TỐI ĐA HOÁ NGÔN NGỮ TIẾNG VIỆT (PHẦN QUAN TRỌNG NHẤT)

Đọc đúng = 7 lớp xử lý nối tiếp. Thiếu 1 lớp là có loại sách đọc sai.
Mọi lớp chạy **trên máy**, bằng TypeScript + native, không gọi mạng.

### Lớp 0 — Cứu chữ: mã hoá & lỗi trích xuất
Đây là lớp các app đọc sách thường không có, nhưng sách Việt cũ rất cần:
- Chuẩn hoá **Unicode NFC** toàn văn (PDF hay xuất chữ dạng tổ hợp NFD — đọc thẳng sẽ sai/thiếu dấu).
- **Phát hiện & chuyển đổi font/mã cũ:** TCVN3 (.VnTime, .VnArial…), VNI, VIQR → Unicode. Sách PDF tiếng Việt đời cũ dùng các mã này rất nhiều; không có lớp này thì trích ra toàn chữ rác.
- Sửa lỗi trích PDF điển hình: chữ bị tách dấu do vị trí glyph, ligature (fi/fl), soft-hyphen vô hình, từ bị ngắt cuối dòng bằng "-" → nối lại, khoảng trắng thừa/thiếu quanh dấu câu kiểu đánh máy cũ ("đây , là").

### Lớp 1 — Cấu trúc sách
- EPUB: đi theo spine đúng thứ tự, nhận diện chương theo heading/TOC, phân biệt thân bài vs chú thích vs mục lục.
- PDF: tái dựng thứ tự đọc đa cột, loại header/footer/số trang lặp, nhận diện tiêu đề theo cỡ chữ/độ đậm.
- Phần tử đặc biệt có quy tắc đọc riêng: **bảng** (đọc theo hàng, nhắc tên cột khi bảng dài), **danh sách** (đọc thứ tự), **thơ** (nghỉ theo dòng thơ, không nối câu qua xuống dòng), **trích dẫn/hội thoại**, **chú thích chân trang** (mặc định bỏ qua, có tuỳ chọn đọc), **công thức** (đọc theo quy tắc toán — Lớp 3).

### Lớp 2 — Chia câu & nhịp đọc
- Bộ chia câu tiếng Việt chuyên dụng: không cắt ở viết tắt (Dr., ThS., TP., tr., v.v., v.v…), số thập phân, ngày tháng, tên riêng viết tắt (Ng. Văn A), dấu ba chấm, hội thoại gạch đầu dòng kiểu Việt Nam.
- Đoạn tổng hợp 120–180 ký tự, ưu tiên cắt ở biên câu → mệnh đề → cụm từ, không bao giờ cắt giữa số/cụm đã chuẩn hoá.
- Bản đồ nhịp nghỉ từ dấu câu: phẩy = nghỉ ngắn, chấm phẩy/hai chấm = trung bình, chấm = dài, đoạn mới = dài hơn, hết chương = dài nhất + (tuỳ chọn) đọc tên chương sau.

### Lớp 3 — Chuẩn hoá văn bản (Text Normalization) — trái tim của project
Port + mở rộng rule Vinorm sang chạy on-device. Mục tiêu số lượng ngay bản 1.0:
**3.000+ mục từ điển viết tắt, 300+ đơn vị đo, 1.000+ thuật ngữ theo thể loại (Lớp 4).**

**3a. Số — làm đúng theo quy tắc tiếng Việt, không đọc kiểu máy:**
- Quy tắc biến âm chuẩn: 21 → "hai mươi **mốt**" (mốt chỉ khi hàng chục ≥2), 15/25 → "mười **lăm** / hai mươi **lăm**" (lăm khi có hàng chục đứng trước), 24 → "hai mươi **tư**" (tuỳ chọn tư/bốn, mặc định tư), 105 → "một trăm **lẻ** năm", 1.005.000 → "một triệu **không trăm lẻ** năm nghìn", lớp nghìn/triệu/tỷ toàn 0 thì bỏ hẳn.
- **Bẫy dấu chấm/phẩy kiểu Việt:** mặc định VN dùng "." ngăn nghìn và "," thập phân (1.250.000 và 15,5 → "mười lăm phẩy năm"). Nhưng sách kỹ thuật/bản dịch dùng kiểu Anh (1,250.5). Bộ suy luận theo mẫu: `1.250.000` = nghìn, `1,5` = thập phân, `1.5` trong ngữ cảnh kỹ thuật = thập phân, `2.0.5` = số phiên bản → "hai chấm không chấm năm". Đây là nhóm test dày nhất (250 câu — Phần C).
- Phân biệt theo ngữ cảnh: **năm** (1945 sau chữ "năm"/ngữ cảnh lịch sử → đọc đủ "một nghìn chín trăm bốn mươi lăm"), **số lượng**, **số thứ tự** ("thứ 3" → "thứ ba", "hạng 1" → "hạng nhất"), **điểm số** (8.5 điểm → "tám phẩy năm điểm" theo kiểu phẩy dù viết chấm — có test riêng), **tỉ số** (2-0 → "hai không"), **tỉ lệ** (3:2), **phân số** (2/3 → "hai phần ba"), **khoảng** (3–5 → "ba đến năm"), **số điện thoại** (đọc theo nhóm 4-3-3), **CCCD/mã số** (đọc từng chữ số), **số La Mã** (thế kỷ XVI → "thế kỷ mười sáu", chương IV, tên vua + số).
- Tiền tệ: VND/đồng/USD/EUR… + cách đọc số tiền rút gọn trong văn nói khi xuất hiện trong hội thoại ("2 triệu mốt" giữ nguyên, không "chuẩn hoá ngược").

**3b. Ngày giờ & thời gian:** 25/12/2023, 12/2020, II/1945 (tháng La Mã), 10:30, 15h30, 5p, thập niên 90, thế kỷ, trước/sau Công nguyên, âm lịch ("rằm tháng Giêng", "mùng 1 Tết" — giữ nguyên dạng nói, không bung số), khoảng thời gian ("từ 8–10 giờ").

**3c. Viết tắt — theo ngữ cảnh, không bung mù:**
- 4 nhóm nền: hành chính (UBND, HĐND, CCCD, BHXH/BHYT, NĐ-CP…), giáo dục–học vị (THCS, THPT, GD&ĐT, SGK, GV/HS/SV, **GS./PGS./TS./ThS.** — xử lý chuỗi "PGS.TS." đứng trước tên người thành "phó giáo sư tiến sĩ" và KHÔNG coi dấu chấm đó là hết câu), doanh nghiệp/pháp lý (TNHH, CTCP, QĐ, TT…), đời thường (v.v., tr., NXB, đ/c…).
- Y khoa (quan trọng với anh): BS, BS.CKI/CKII, ĐTĐ, THA, XN, CLS, HA, SpO2, đơn vị mg/ml/mmHg ("mi-li-mét thuỷ ngân"), mmol/L, °C…
- **Khử đa nghĩa bằng ngữ cảnh:** cùng 1 chữ tắt khác nghĩa theo lĩnh vực (VD "CĐ" = cao đẳng trong giáo dục, công điện trong văn bản) — engine xét từ xung quanh + thể loại sách đang mở để chọn nghĩa; không chắc chắn thì đọc đánh vần chữ cái thay vì bung sai.
- Viết tắt tiếng Anh: phân biệt loại đọc nguyên từ (WHO, COVID-19), loại đánh vần (USA trong văn bản trang trọng), loại đã Việt hoá (ô tô, ti vi…) — theo từ điển, không đoán.

**3d. Tên riêng & ngoại ngữ:**
- Tên người Việt: giữ nguyên (engine tự xử lý thanh điệu), chuỗi họ tên viết tắt có quy tắc riêng.
- **Tên Hán-Việt trong truyện tiên hiệp/kiếm hiệp/lịch sử: đọc theo âm Hán-Việt** (tên nhân vật, môn phái, địa danh, chiêu thức) — có từ điển Hán-Việt theo thể loại ở Lớp 4; tuyệt đối không để engine đọc kiểu tiếng Anh/tiếng Trung.
- Từ tiếng Anh lẫn câu Việt: giữ nguyên chính tả để VieNeu tự code-switch Anh–Việt (điểm mạnh riêng của v3 Turbo, tiếng Việt sát, tiếng Anh không bị nuốt); thuật ngữ Anh chuyên ngành có mục từ điển phát âm riêng khi engine đọc chưa đúng.
- Thuật ngữ Pali/Sanskrit (sách Phật giáo), tiếng Pháp (văn học cũ), tiếng Hán phiên âm: mỗi nhóm 1 bảng tra riêng trong gói thể loại.

**3e. Toán & ký hiệu:** +, −, ×, ÷, =, <, >, %, ‰, √, x², H₂O ("hát hai ô"), NaCl, tọa độ, kinh vĩ độ, ký hiệu tiền tệ/nhiệt độ/góc — bảng quy tắc riêng, có test.

### Lớp 4 — Gói từ điển theo thể loại (tải thêm như tải giọng!)
Ý tưởng then chốt của bản FULL: **từ điển cũng đóng gói và tải theo nhu cầu như giọng.**
Mỗi gói là 1 file JSON nhỏ (vài trăm KB) trên GitHub, app tải 1 lần là dùng offline mãi:
`Y khoa` · `Tiên hiệp – Kiếm hiệp` · `Lịch sử – Quân sự` · `Phật giáo` · `Công giáo` · `Pháp luật – Hành chính` · `Kinh tế – Tài chính` · `Công nghệ` · `Văn học cổ`
Mỗi gói gồm: bảng viết tắt riêng của ngành + thuật ngữ + tên riêng thường gặp + cách đọc đã kiểm chứng. Mở sách thuộc thể loại nào, app gợi ý tải gói đó.

### Lớp 5 — Từ điển cá nhân theo từng cuốn sách (tính năng "giết người" cho truyện dài)
- Đang nghe mà gặp tên đọc sai: **chạm giữ vào từ đó → "Sửa cách đọc"** → gõ cách đọc đúng 1 lần → app đọc lại ngay câu đó và **nhớ cho cả cuốn sách** (và tuỳ chọn: cho mọi sách).
- Từ điển cá nhân xuất/nhập file được, đồng bộ qua file (không server), áp dụng trước mọi lớp chuẩn hoá khác.

### Lớp 6 — G2P & tổng hợp
- Dùng **sea-g2p** của chính VieNeu làm phonemizer — không tự chế tầng âm vị, tránh xung đột với model. Can thiệp duy nhất: từ điển Lớp 4/5 thay text TRƯỚC khi vào G2P.
- Sau tổng hợp: kiểm tra độ dài audio bất thường so với số ký tự (câu nào audio ngắn/dài bất thường = nghi nuốt chữ → tự tổng hợp lại 1 lần với seed khác, vẫn lỗi thì đánh dấu trong chẩn đoán).

### Lớp 7 — Vòng phản hồi chất lượng
- Màn hình Chẩn đoán (kiểu Bút Nghiên): engine đang dùng, giọng, câu đang đọc, text gốc → text sau chuẩn hoá (xem được từng câu trước khi nghe), log lỗi.
- Nút "Báo câu đọc sai" ngay trong player: lưu câu đó vào danh sách chờ sửa từ điển — đây là nguồn bổ sung test vàng thực tế nhất.

---

## PHẦN C — TEST KĨ CÀNG (KHÔNG QUA TEST LÀ KHÔNG PHÁT HÀNH)

### C1. Bộ test vàng ngôn ngữ — 1.000 câu, chia nhóm có quota
| Nhóm | Số câu | Ví dụ bẫy |
|---|---|---|
| Số đếm & biến âm mốt/tư/lăm/lẻ | 150 | 21, 101, 115, 1.005.000, 15.000.700 |
| Thập phân & bẫy chấm/phẩy VN–Anh | 100 | 1,5 · 1.5 · 1.250,75 · 2.0.5 · 8.5 điểm |
| Ngày/giờ/thế kỷ/khoảng | 80 | 25/12/2023 · II/1945 · từ 8–10 giờ |
| Tiền tệ & đơn vị đo (gồm y khoa) | 100 | 37,5°C · 120/80 mmHg · 5 mg/kg |
| Viết tắt 4 nhóm + đa nghĩa | 150 | PGS.TS. · UBND · CĐ hai nghĩa |
| Y khoa chuyên sâu | 80 | BS.CKII · SpO2 98% · mmol/L |
| Tên Hán-Việt / tiên hiệp / lịch sử | 80 | tên nhân vật, môn phái, chiêu thức |
| Anh–Việt lẫn (code-switch) | 80 | thuật ngữ, tên riêng, COVID-19 |
| Hội thoại / thơ / trích dẫn | 60 | gạch đầu dòng, thơ lục bát, ba chấm |
| Rác trích xuất PDF & mã cũ | 70 | NFD, TCVN3, từ ngắt dòng, "đây , là" |
| Toán & ký hiệu | 50 | 2/3 · H₂O · 3:2 · x² |
| **Tổng** | **1.000** | Mỗi câu: text gốc → đáp án chuẩn hoá → (tuỳ chọn) ghi chú |

- Cách chạy: test tự động so khớp đáp án 100% cho nhóm số/ngày/viết tắt (sai 1 câu là đỏ CI, chặn merge); nhóm tên riêng/ngoại ngữ cho phép danh sách đáp án chấp nhận được.
- Mỗi lỗi anh báo từ máy thật (Lớp 7) → thành 1 câu test vàng mới. Bộ test chỉ tăng, không giảm.

### C2. Corpus sách thật để test trích xuất — 12 cuốn mẫu cố định
EPUB truyện dài · EPUB sách kiến thức · PDF giáo trình y khoa (2 cột) · PDF văn học 1 cột ·
PDF scan (OCR) · PDF mã TCVN3 cũ · sách thơ · sách lịch sử nhiều số La Mã ·
sách song ngữ Anh–Việt · sách có bảng biểu · sách có công thức · file hỏng/trùng lặp (test báo lỗi tử tế)
Chỉ số qua cửa: sai ký tự <0,5% với sách có text layer · nhận diện chương đúng ≥98% ·
0 câu bị mất / trùng lặp khi đọc liên tục 1 chương.

### C3. Test giọng
- Mỗi giọng: đọc cùng 100 câu chuẩn (đủ thanh điệu, số, hội thoại) → kiểm tra: không nuốt chữ (độ dài audio hợp lệ 100/100), không lặp, không im lặng bất thường.
- Nghe chấm điểm mù trên máy thật của anh: thang 1–5 cho Tự nhiên / Rõ chữ / Đúng ngữ điệu — giọng nào <3,5 điểm thì gắn nhãn "đang hoàn thiện" trong app, không để mặc định.
- Test ổn định giọng dài hạn: cùng 1 giọng đọc liên tục 1 chương 5.000 chữ, kiểm tra giọng không drift/đổi tông giữa chừng.

### C4. Test máy thật & độ bền (theo đúng bài học các project trước: hypothesis phải kiểm chứng trên máy)
- Ma trận máy: iPhone chính của anh (máy quyết định), 1 iPhone đời cũ hơn, 1 Android tầm trung.
- **Test offline tuyệt đối:** bật máy bay từ đầu → mở sách, tải… (không tải được là đúng) → nghe trọn 1 chương bằng giọng đã tải: phải chạy 100%, app phát 0 request mạng (kiểm chứng bằng log).
- **Soak test 8 giờ:** đọc liên tục 1 cuốn qua đêm — không crash, không rò bộ nhớ (RAM giữ phẳng), máy không nóng bất thường (nếu nóng: tự hạ từ Turbo fp32 → int8 → Nano theo nhiệt, có báo nhẹ).
- Ngắt quãng thật: cuộc gọi đến, báo thức, Siri, rút tai nghe, khoá/mở màn hình, app bị hệ thống kill rồi mở lại → mở lại đúng câu đang nghe dở.
- Chỉ số hiệu năng qua cửa: bấm Nghe → có tiếng <1,5 giây (core đã nạp) · RTF int8 trên iPhone <1 (đọc nhanh hơn thời gian thực) · pin <8%/giờ nghe.

### C5. CI trên GitHub Actions
Mỗi lần push: test vàng 1.000 câu · test trích xuất corpus · kiểm tra manifest giọng (SHA-256 khớp, link Releases sống, license có khai báo) · build thử iOS/Android. Đỏ bất kỳ mục nào là không ra bản mới.

---

## PHẦN D — READER, PLAYER, GIAO DIỆN (BẢN FULL)

- **Thư viện:** nhập sách từ Files/Share Sheet, tự lấy bìa + metadata EPUB, kệ theo thể loại/tác giả, tìm kiếm full-text trong sách, ghi nhớ vị trí đọc theo câu (không chỉ theo trang — nghe dở mở lại là đúng câu đó).
- **Reader:** chữ Be Vietnam Pro, cỡ chữ/dãn dòng/nền giấy–tối theo hệ Appllama + Liquid Glass đã dùng ở AnkiLearning/Bút Nghiên (mang nguyên design system sang, không vẽ lại), chế độ đọc trang/cuộn, highlight chạy theo câu đang nghe, chạm giữ vào từ để sửa cách đọc (Lớp 5).
- **Player:** màn hình nghe riêng gọn kiểu Bút Nghiên đợt 17 (rail trái trên mobile, không intro, không chữ thừa), điều khiển khoá màn hình/tai nghe, hẹn giờ ngủ (hết chương / 15–60 phút / lắc để thêm giờ), tua theo câu (không tua theo giây — nghe sách phải tua theo câu), bookmark bằng giọng nói… (ghi chú: bookmark để lại bằng nút bấm khi đang nghe).
- **Không có:** đăng nhập, quảng cáo, theo dõi, bất kỳ chữ nào nhắc tới hạ tầng bên trong (đúng gu của anh: chỉ nhãn chức năng ngắn gọn).

## PHẦN E — PHÂN PHỐI TRÊN GITHUB

```
Repo: hieuka001/<tên-anh-chốt>   (public — để Releases tải không cần token)
├─ code + text-engine + golden-tests/1000-cau.json
├─ voices/voices.json          (danh mục — app đọc file này qua raw URL khi có mạng,
│                                và dùng bản cache trong máy khi offline)
└─ dict-packs/*.json           (gói từ điển thể loại — file nhỏ, để thẳng trong repo)

Releases:
  core-vieneu-turbo-int8-v1    vieneu-core-int8.zip
  core-vieneu-turbo-fp32-v1    vieneu-core-fp32.zip
  core-vieneu-nano-v1          vieneu-nano.zip
  voices-piper-v1              từng file .onnx theo giọng
  app-ios-vX / app-android-vX  bản cài + bản tự cập nhật (như AnkiLearning)
```
Mỗi asset kèm SHA-256 trong manifest; app tải dở được tải tiếp (resume), tải xong verify mới kích hoạt, hỏng thì xoá và báo rõ — không bao giờ để app rơi vào trạng thái "giọng hỏng không rõ lý do".

## PHẦN F — LỘ TRÌNH & CỬA NGHIỆM THU

0. **Nền móng:** repo + CI + manifest + bộ test vàng viết trước 300 câu đầu — *cửa: CI xanh*
1. **Text Engine:** Lớp 0–3 + từ điển 3.000 mục — *cửa: 1.000/1.000 test vàng*
2. **Reader offline:** EPUB/PDF + thư viện + Lớp 1 — *cửa: corpus 12 cuốn đạt chỉ số C2*
3. **Giọng NHẸ + CHUẨN:** Piper từng giọng + VieNeu int8 core — *cửa: offline tuyệt đối + soak 2 giờ*
4. **Giọng MAX + clone + gói thể loại + từ điển cá nhân** — *cửa: chấm điểm mù của anh ≥4/5 giọng mặc định*
5. **Hoàn thiện:** soak 8 giờ, pin/nhiệt, bản Android — *cửa: checklist C4 đạt hết trên máy anh*

Việc duy nhất thuộc về anh ở mỗi chặng: nghe thử trên iPhone và chấm điểm — phần còn lại em tự chạy theo thiết kế này, không hỏi lại từng bước.
