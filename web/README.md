# Website: tài liệu + bảng tính lợi nhuận

Trang tĩnh, không build step, không dependency. Mở là chạy; deploy được nguyên thư mục `web/` lên Cloudflare Pages hoặc Vercel.

## Xem tại máy

```bash
python3 -m http.server -d web 8080
# http://localhost:8080/            trang chủ + bảng tính
# http://localhost:8080/docs.html   tài liệu
```

Phải chạy qua HTTP server: trang tài liệu đọc file Markdown bằng `fetch()`, nên mở bằng `file://` sẽ bị chặn.

## Deploy

**Cloudflare Pages** — kết nối repo, đặt:

| Trường | Giá trị |
|---|---|
| Framework preset | None |
| Build command | *(để trống)* |
| Build output directory | `web` |

**Vercel** — import repo, đặt Framework Preset = *Other*, Root Directory = `web`, Build Command để trống, Output Directory = `.`. Hoặc chạy CLI:

```bash
cd web && npx vercel deploy --prod
```

**Bất kỳ static host nào** — copy nội dung `web/` lên (nginx, Caddy, S3, GitHub Pages). Không cần rewrite rule: mọi trang là file thật, `404.html` được Cloudflare Pages tự dùng.

### Header bảo mật

- `_headers` dùng cho Cloudflare Pages và Netlify.
- `vercel.json` dùng cho Vercel.

Cả hai đặt CSP `script-src 'self'` (không có inline script), chặn iframe, và chỉ cho phép gọi đúng một domain ngoài: `api.coingecko.com` cho nút "Lấy giá". Nếu bạn không muốn request ngoài nào cả, xoá domain đó khỏi `connect-src`; nút giá sẽ báo lỗi và bạn nhập tay.

## Cấu trúc

```
index.html            trang chủ + bảng tính nhiều máy
docs.html             khung tài liệu (sidebar, tìm kiếm, routing theo #hash)
404.html
assets/site.css       toàn bộ style, sáng/tối, in ấn
assets/site.js        theme, copy button, format số
assets/md.js          renderer Markdown tối giản (không HTML thô từ nội dung)
assets/docs.js        nạp mục lục, render trang, tìm kiếm client-side
assets/rig.js         giải mã ZMRIG1.*, công thức điện/lợi nhuận (hàm thuần)
assets/dash.js        giao diện bảng tính, localStorage, xuất/nhập JSON
assets/builder.js     ghép lệnh cài đặt từ các tuỳ chọn (mục #builder)
content/vi/index.json danh sách trang
content/vi/*.md       nội dung tài liệu
```

## Thêm ngôn ngữ

1. Tạo `content/<lang>/` với `index.json` và các file `.md`.
2. Trong `assets/docs.js`, đổi `var BASE = "content/vi/";` thành giá trị bạn muốn (hoặc đọc từ query string `?lang=`).
3. Thêm nút chuyển ngôn ngữ vào `docs.html`.

Không cần build lại gì.

## Ghi chú kỹ thuật

- **Không có framework.** Tổng JS khoảng 30 KB chưa nén, tải một lần, chạy offline sau đó (trừ nút lấy giá).
- **Không có tracking, không cookie, không analytics.** Trạng thái bảng tính nằm trong `localStorage` của trình duyệt.
- **Không gửi mã máy đi đâu.** `rig.js` giải mã base64 và tính toán tại chỗ.
- **Markdown được escape trước khi render**, nên nội dung không thể chèn HTML/script.
- **In được**: `Ctrl-P` trên bảng tính cho ra bảng sạch (đã có `@media print`).
- **Truy cập**: label đầy đủ, `aria-live` cho thông báo, focus ring rõ, tôn trọng `prefers-reduced-motion`, hỗ trợ bàn phím.

## Định dạng mã báo cáo

`ZMRIG1.` + base64url(JSON). Ví dụ payload:

```json
{"v":1,"id":"vps-hn-01","ver":"6.26.0-mo9","cpu":"AMD EPYC 7B13","arch":"x86_64",
 "cores":32,"thr":16,"algo":"rx/0","mode":"fast","hs":[9620.4,9588.1,9510.7,9712.0],
 "hp":[1168,1168],"shares":[412,1,0],"hash":8123456789,"up":86400,
 "pw":118.4,"pwsrc":"rapl","pool":"gulf.moneroocean.stream:10001","ts":1700000000}
```

Parser chấp nhận: một mã, nhiều mã cách nhau bởi xuống dòng/dấu phẩy, hoặc JSON thô (một object hay một mảng). Trường lạ bị bỏ qua; thiếu `hs` thì báo lỗi rõ ràng.
