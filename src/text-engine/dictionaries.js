// dictionaries.js — Từ điển viết tắt / đơn vị / ký hiệu cho Text Normalization.
// Bản 1.0: hạt nhân đã kiểm chứng. Mục tiêu mở rộng: 3.000+ viết tắt, 300+ đơn vị
// (xem THIET-KE-FULL.md) — thêm mục mới = thêm 1 dòng + 1 câu test vàng.
// Key viết tắt viết đúng dạng thường gặp trong sách (phân biệt hoa/thường khi cần).

export const ABBREVIATIONS = {
  // Hành chính / nhà nước
  "UBND": "ủy ban nhân dân", "HĐND": "hội đồng nhân dân", "CCCD": "căn cước công dân",
  "CMND": "chứng minh nhân dân", "BHXH": "bảo hiểm xã hội", "BHYT": "bảo hiểm y tế",
  "CSGT": "cảnh sát giao thông", "PCCC": "phòng cháy chữa cháy", "TW": "trung ương",
  "CP": "chính phủ", "QH": "quốc hội", "NXB": "nhà xuất bản", "TAND": "tòa án nhân dân",
  "VKSND": "viện kiểm sát nhân dân", "MTTQ": "mặt trận tổ quốc", "HĐQT": "hội đồng quản trị",
  // Giáo dục / học vị / học hàm
  "THCS": "trung học cơ sở", "THPT": "trung học phổ thông", "TH": "tiểu học",
  "GD&ĐT": "giáo dục và đào tạo", "SGK": "sách giáo khoa", "GV": "giáo viên",
  "HS": "học sinh", "SV": "sinh viên", "ĐH": "đại học", "CĐ": "cao đẳng",
  "GS": "giáo sư", "PGS": "phó giáo sư", "TS": "tiến sĩ", "ThS": "thạc sĩ",
  "CN": "cử nhân", "KS": "kỹ sư", "NCS": "nghiên cứu sinh",
  // Y khoa
  "BS": "bác sĩ", "CKI": "chuyên khoa một", "CKII": "chuyên khoa hai",
  "BN": "bệnh nhân", "ĐTĐ": "đái tháo đường", "THA": "tăng huyết áp",
  "HA": "huyết áp", "XN": "xét nghiệm", "CLS": "cận lâm sàng",
  "BV": "bệnh viện", "PK": "phòng khám", "ICU": "hồi sức tích cực",
  "HIV": "hát i vê", "AIDS": "ết", "MRI": "em rai", "CT": "xê tê",
  // Pháp lý / doanh nghiệp / kinh tế
  "TNHH": "trách nhiệm hữu hạn", "CTCP": "công ty cổ phần", "CPH": "cổ phần hóa",
  "QĐ": "quyết định", "NĐ": "nghị định", "TTg": "thủ tướng", "GDP": "gờ đê pê",
  "VAT": "thuế giá trị gia tăng", "TNDN": "thu nhập doanh nghiệp", "ATM": "cây ây ti em",
  // Đời thường / sách vở
  "TP": "thành phố", "TX": "thị xã", "TT": "thị trấn", "Q": "quận", "P": "phường",
  "tr": "trang", "v.v": "vân vân", "vv": "vân vân", "Đ/c": "đồng chí", "đ/c": "đồng chí",
  "KTS": "kiến trúc sư", "NTK": "nhà thiết kế", "BTV": "biên tập viên", "MC": "em xi",
  // Tổ chức quốc tế / tiếng Anh đã Việt hoá cách đọc
  "WHO": "tổ chức y tế thế giới", "UN": "liên hợp quốc", "UNESCO": "iu nét cô",
  "USA": "hoa kỳ", "EU": "liên minh châu âu", "ASEAN": "a xê an", "FBI": "ép bi ai",
  "NASA": "na xa", "COVID": "covid", "Covid": "covid",
  // Chức danh đứng trước tên người (có dấu chấm trong văn bản gốc)
  "Dr": "bác sĩ", "Mr": "ông", "Mrs": "bà", "Ms": "cô",
};

// Chuỗi học vị dính nhau kiểu "PGS.TS." / "GS.TS." — xử lý trước viết tắt đơn.
export const TITLE_CHAINS = {
  "PGS.TS": "phó giáo sư tiến sĩ", "GS.TS": "giáo sư tiến sĩ",
  "PGS.TSKH": "phó giáo sư tiến sĩ khoa học", "BS.CKII": "bác sĩ chuyên khoa hai",
  "BS.CKI": "bác sĩ chuyên khoa một", "ThS.BS": "thạc sĩ bác sĩ",
  "TS.BS": "tiến sĩ bác sĩ", "GS.TSKH": "giáo sư tiến sĩ khoa học",
};

// Đơn vị đo — key là ký hiệu, value là cách đọc. Thứ tự: ký hiệu dài trước khi tra.
export const UNITS = {
  "mmHg": "mi li mét thủy ngân",
  "mmol/L": "mi li mol trên lít", "mg/dL": "mi li gam trên đề xi lít",
  "km/h": "ki lô mét trên giờ", "m/s": "mét trên giây",
  "kg": "ki lô gam", "mg": "mi li gam", "mcg": "mi cờ rô gam", "µg": "mi cờ rô gam",
  "km": "ki lô mét", "cm": "xăng ti mét", "mm": "mi li mét", "nm": "na nô mét",
  "ml": "mi li lít", "mL": "mi li lít", "dl": "đề xi lít", "dL": "đề xi lít",
  "ha": "héc ta", "m2": "mét vuông", "m²": "mét vuông", "km2": "ki lô mét vuông",
  "m3": "mét khối", "m³": "mét khối",
  "°C": "độ xê", "°F": "độ ép", "K": "độ ken vin",
  "Hz": "héc", "kHz": "ki lô héc", "MHz": "mê ga héc", "GHz": "gi ga héc",
  "kW": "ki lô oát", "MW": "mê ga oát", "kWh": "ki lô oát giờ",
  "V": "vôn", "A": "am pe", "W": "oát", "J": "giun", "N": "niu tơn", "Pa": "pát can",
  "g": "gam", "l": "lít", "L": "lít", "s": "giây", "m": "mét", "ms": "mi li giây",
  "kcal": "ki lô ca lo", "cal": "ca lo", "IU": "đơn vị quốc tế",
  "VND": "đồng", "USD": "đô la mỹ", "EUR": "ơ rô", "JPY": "yên nhật", "GBP": "bảng anh",
};

// Tên chữ cái tiếng Anh đọc theo kiểu Việt (cho mã hoá học, viết tắt đánh vần).
export const LETTER_NAMES = {
  a: "a", b: "bê", c: "xê", d: "đê", e: "e", f: "ép", g: "gờ", h: "hát", i: "i",
  j: "giây", k: "ca", l: "en lờ", m: "em mờ", n: "en nờ", o: "ô", p: "pê", q: "quy",
  r: "e rờ", s: "ét", t: "tê", u: "u", v: "vê", w: "vê kép", x: "ích", y: "i dài", z: "dét",
};

// Token đặc biệt đọc nguyên dạng cố định.
export const SPECIAL_TOKENS = {
  "SpO2": "sp o hai", "SpO₂": "sp o hai", "H2O": "hát hai ô", "H₂O": "hát hai ô",
  "CO2": "xê ô hai", "O2": "ô hai", "NaCl": "nát ri cờ lo rua",
};
