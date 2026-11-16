# Project mới: App đọc sách PDF/EPUB offline + TTS tải giọng theo nhu cầu

Ngày lập: 2026-11-16
Trạng thái: BẢN THIẾT KẾ ĐỂ DUYỆT — chưa code

## 1. Mục tiêu đúng như anh mô tả
- Đọc file PDF và EPUB, chạy hoàn toàn offline (không server, không Firebase, không API key)
- Bản điện thoại rất nhẹ khi mới cài
- Muốn nghe giọng nào thì bấm Download giọng đó về máy, chạy local 100%
- Toàn bộ giọng host trên GitHub của mình (hieuka001)
- Ưu tiên đặc biệt: cơ chế đọc phải ĐÚNG và CHUẨN XÁC về ngôn ngữ

## 2. Điểm phải sửa trong ý tưởng gốc (đã kiểm chứng)

### 2.1. Không up giọng thẳng vào git repo được
- GitHub chặn cứng file >100 MiB khi push vào repo, cảnh báo từ 50 MiB.
- Cách đúng và miễn phí: giọng để ở **GitHub Releases** — mỗi asset tối đa 2 GiB,
  tối đa 1000 asset / release, không giới hạn tổng dung lượng và băng thông tải.
- Repo chỉ chứa: code + `voices.json` (danh mục, <1MB) + file nghe thử MP3 nhỏ.
- App đọc `voices.json` từ repo, khi bấm tải thì tải asset từ Releases,
  kiểm tra SHA-256 rồi mới kích hoạt.

### 2.2. VieNeu không có "mỗi giọng 1 file model riêng"
Đây là bài học từ Bút Nghiên đợt 31:
- VieNeu v3 Turbo = **1 core chung** (~166MB backbone int8 + ~86MB codec,
  tổng gói int8 đo thực tế ~327MB) + mỗi giọng chỉ là 1 bộ tham số <1MB
  trong `voices_v3_turbo.json`. 25 giọng Bắc/Trung/Nam đều chạy trên core này.
- VieNeu v3 Nano: model 48M tham số, 24kHz, nhanh hơn ~3 lần, 11 giọng preset,
  nhưng chất lượng thấp hơn Turbo — nhất là khi gặp tiếng Anh lẫn tiếng Việt.
- Ngược lại, Piper/VITS thì mỗi giọng là 1 file ONNX độc lập thật:
  ví dụ giọng Việt `vi_VN-vais1000-medium.onnx` = 61MB (bản low ~16MB, high ~113MB),
  không cần core chung — nhưng giọng Việt Piper rất ít và chất lượng dưới VieNeu.

### 2.3. Kiến trúc chốt đề xuất: 2 tầng tải
```
App cài mới:                         ~20-25 MB  (chỉ có reader + thư viện + player)
  └─ Tải lần 1 (chọn 1 trong 2):
       A. Gói Nhẹ — Piper/VITS: mỗi giọng 16-63MB, tải giọng nào dùng giọng đó,
          không core, nghe ngay, chất lượng khá
       B. Gói Chuẩn — VieNeu Core int8: tải 1 lần ~250-330MB,
          sau đó 25 giọng VieNeu mỗi giọng <2MB, bấm là nghe ngay,
          chất lượng tiếng Việt tốt nhất, đọc Anh-Việt lẫn nhau đúng nhất
  └─ Xoá giọng / xoá core bất cứ lúc nào trong Cài đặt > Dung lượng
```
Như vậy app vẫn "nhẹ" đúng nghĩa, và "tải từng giọng" vẫn đúng ở tầng A,
còn tầng B là "tải core 1 lần, giọng gần như miễn phí" — ghi rõ dung lượng
trước khi tải để người dùng không bị bất ngờ.

## 3. Cơ chế đọc chuẩn xác — phần quan trọng nhất

Đọc sai phần lớn không do model giọng, mà do 3 tầng xử lý text trước khi
đưa vào TTS. Thiết kế đủ 3 tầng:

### Tầng 1 — Trích text đúng thứ tự đọc
- **EPUB (chuẩn nhất):** parse OPF/spine theo đúng thứ tự chương của sách,
  đọc XHTML, bỏ ghi chú chân trang/mục lục lặp, giữ tiêu đề chương để nghỉ
  hơi lâu hơn. EPUB luôn cho kết quả chính xác hơn PDF.
- **PDF có text layer:** dùng pdf.js/MuPDF, tái dựng thứ tự đọc:
  phát hiện cột, loại header/footer và số trang lặp ở mọi trang,
  nối lại từ bị ngắt dòng bằng dấu gạch nối cuối dòng (hyphenation),
  chuẩn hoá Unicode về NFC (bắt buộc với dấu tiếng Việt — NFD sẽ đọc sai dấu).
- **PDF scan (không có text layer):** phải OCR offline (Tesseract/ML Kit).
  Sẽ báo rõ trong app "sách scan — độ chính xác phụ thuộc OCR",
  không hứa đọc đúng 100% với loại này.

### Tầng 2 — Chia câu không cắt nhầm
- Bộ chia câu riêng cho tiếng Việt, không dùng split('.') đơn giản.
- Không cắt ở: viết tắt (Dr., ThS., BS., TP., tr., v.v.), số thập phân (2.5),
  ngày tháng, dấu ba chấm, chữ viết tắt tiếng Anh.
- Cắt đoạn tổng hợp ở 120-180 ký tự (kinh nghiệm Bút Nghiên: 200 là giới hạn
  an toàn, dài hơn engine dễ nuốt chữ/dừng giữa chừng), luôn cắt ở biên câu/mệnh đề.
- Tiêu đề, đầu chương, đoạn mới = điểm nghỉ có chủ đích.

### Tầng 3 — Chuẩn hoá văn bản (Text Normalization) trước khi đọc
Port lại rule của Vinorm sang TypeScript/Kotlin/Swift chạy ngay trên máy
(Vinorm gốc là C++/Linux, vinormx là Python — đều không chạy trực tiếp trên
điện thoại được, phải port rule, không phụ thuộc server):
- Số: phân biệt số đếm / năm / số điện thoại / số thập phân / phân số / tỉ lệ.
  VD: `2023` đọc theo ngữ cảnh năm khác với số lượng.
- Ngày giờ: `25/12/2023` → "ngày hai mươi lăm tháng mười hai năm...",
  `10:30`, `15h30` → dạng nói.
- Tiền tệ, đơn vị đo: `100 USD`, `2.5 triệu VND`, `5kg`, `37°C`, `90%`.
- Viết tắt có từ điển mở rộng được: Dr. → bác sĩ, WHO, COVID-19, TP.HCM...
- Số La Mã, ký hiệu toán học, email/website (đọc đánh vần hoặc bỏ qua theo tuỳ chọn).
- Từ tiếng Anh lẫn trong câu Việt: giữ nguyên để VieNeu tự xử lý code-switch
  (điểm mạnh của v3 Turbo), không phiên âm bừa ở tầng này.
- Sau chuẩn hoá mới đưa qua G2P của chính engine (VieNeu dùng sea-g2p),
  không can thiệp tầng âm vị.

### Bộ test vàng (bắt buộc có từ ngày đầu)
- 200+ câu mẫu bao phủ: số/ngày/giờ/tiền/đơn vị, y khoa, viết tắt,
  câu dài, câu có tiếng Anh, thơ, hội thoại.
- Mỗi câu có đáp án chuẩn hoá mong đợi — sửa rule mà test đỏ là không merge.
- Đây là cách duy nhất giữ "đọc đúng" khi project lớn dần.

## 4. Kiến trúc app (tái dùng phần đã chứng minh được)
- Vỏ: Capacitor 6 (giống Bút Nghiên/STV — đã có sẵn cầu native TTS + ONNX
  Runtime, cài qua ESign, chạy nền/khoá màn hình được)
- Frontend local 100%: thư viện sách trên máy (file system + IndexedDB metadata),
  không đăng nhập, không đồng bộ cloud
- Reader: EPUB = epub.js, PDF = pdf.js — đều chạy local, đã dùng ở LearningBooks
- Player: highlight theo câu đang đọc, prefetch tổng hợp trước 2 câu,
  tốc độ 0.75-2x, hẹn giờ tắt, điều khiển ở màn hình khoá
- Download Manager: tải resume được khi đứt mạng, hiện % + dung lượng thật,
  verify SHA-256, lưu ở Application Support (iOS) / app-specific storage (Android)

## 5. Cấu trúc repo GitHub đề xuất
```
hieuka001/sach-noi-offline        (tên tạm — anh chọn tên cuối)
├─ app/                code Capacitor + frontend
├─ native-tts/         cầu ONNX Runtime cho iOS/Android
├─ text-engine/        tầng 1-2-3 ở trên + bộ test vàng
├─ voices/
│  └─ voices.json      danh mục: id, tên, vùng miền, giới tính, engine,
│                      size, sha256, release URL, file nghe thử
└─ tools/
   ├─ pack-voice/      đóng gói + tính sha256 + sinh voices.json
   └─ upload-release/  đăng asset lên Releases theo tag voices-v1, core-v1...

GitHub Releases:
  tag core-vieneu-int8-v1  -> vieneu-core-int8.zip (~250-330MB)
  tag voices-v1            -> piper-vi-vais1000-medium.onnx (61MB), ...
```

## 6. Lộ trình
1. M1 — Reader offline: mở EPUB/PDF, thư viện local, nhớ vị trí đọc (chưa có giọng)
2. M2 — Text engine + test vàng 200 câu đạt 100%
3. M3 — Tầng Piper/VITS: tải từng giọng từ Releases, nghe offline
4. M4 — VieNeu Core pack: tải core 1 lần + 25 giọng, so chất lượng trên máy anh
5. M5 — Player hoàn chỉnh: khoá màn hình, highlight, hẹn giờ

## 7. Quyết định cần anh chốt trước khi em dựng repo
1. Tên project / tên repo?
2. Chấp nhận mô hình 2 tầng tải ở mục 2.3 không, hay chỉ lấy 1 engine duy nhất?
3. Ưu tiên iOS trước (như Bút Nghiên) hay làm cả Android cùng lúc?
