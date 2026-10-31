---
title: Lỗi thường gặp
description: Bảng triệu chứng → nguyên nhân cho những lỗi thật sự xảy ra, những bug đã sửa để bạn không phải gặp, và cần gửi gì khi báo lỗi.
---

# Lỗi thường gặp

## Triệu chứng → nguyên nhân

| Triệu chứng | Nguyên nhân thường gặp | Làm gì |
| --- | --- | --- |
| `dataset ready` mất 20–30 s | bình thường: dựng 2 GiB | không phải lỗi; `--mode light` mất 0.6 s nhưng chỉ còn 9 % hashrate |
| hashrate thấp hơn kỳ vọng 20–30 % | không được cấp huge pages | `grep HugePages /proc/meminfo`; log phải ghi `huge pages 2336 MB` |
| process bị kill, exit 137 | hết RAM khi dựng dataset (huge pages đã giữ phần còn lại) | sửa phần đặt trước huge page, hoặc dùng `--mode light` |
| `cannot read …: check the path or run as root` | config chỉ root đọc được | chạy bằng `sudo` |
| `config ok` nhưng không đào gì | thiếu `-c`, hoặc chưa có pool | `--check` chỉ kiểm tra file được đưa |
| `login failed: …` lặp lại | sai ví hoặc sai pool, IP bị ban, sai chế độ TLS | đọc dòng ngay sau nó; thử `--transport tcp` để loại trừ TLS |
| `connection lost` liên tục | CDN hoặc NAT cắt socket im lặng | `--keepalive-interval 60`, `--idle-timeout 120` |
| `share rejected: …` | job hoặc độ khó cũ, hoặc đồng hồ máy bị lệch | kiểm tra `timedatectl`; đọc thông báo của chính pool |
| API trả 401 | có cấu hình access token | gửi `Authorization: Bearer TOKEN` |
| API không tới được từ máy khác | nó bind `127.0.0.1` theo thiết kế | đừng mở ra; dùng SSH tunnel |
| `--tls-ca` không có tác dụng | file nằm trong `/tmp` mà unit dùng `PrivateTmp` | đặt ở `/etc/zmrig/tls-ca.pem` |

## Những bug đã sửa, để bạn không phải gặp

- **`--background` bị bỏ qua** và miner ở lại foreground. Giờ nó fork, gọi
  `setsid` và đóng stdio.
- **Kết nối lại chậm rồi thành bão.** Nó chờ hết `--retry-pause` sau mỗi lần rớt
  và đặt lại bộ đếm khi đổi pool, nên một pool chết bị dập liên tục. Giờ: kết nối
  lại ngay sau phiên đã login được, rồi 200 ms → 500 ms → 1 s → `--retry-pause`,
  với bộ đếm không đặt lại.
- **File log chứa mã màu ANSI.** File là văn bản thường; stdout vẫn giữ màu.
- **Cờ dòng lệnh từng ghi đè config bằng giá trị mặc định.**
  `zmrig -c config.json --verbose` đặt lại `mode`, `huge-pages`, `retries`. Giờ
  chỉ cờ bạn thật sự gõ mới ghi đè.
- **`report.enabled` trong config khởi động `--report`** (đo, in, thoát) thay vì
  chỉ ghi file báo cáo. Hai việc giờ đã tách.
- **`--tls` từng ngụ ý "không kiểm tra chứng chỉ".** Nó chỉ chọn transport; việc
  xác thực vẫn bật.
- **Một dòng quá dài từ pool làm chết phiên.** Dòng đó bị bỏ và cảnh báo một lần
  khi phiên kết thúc.
- **`--http-port` không bao giờ vào tới config.** Đã sửa; installer ghi đúng giá
  trị boolean `enabled`.
- **Ctrl-C bị treo khi đang chờ login.** Monitor đóng socket để thread chính
  thoát.
- **Client mở socket API rồi im lặng làm nghẽn thread API.** Giờ mỗi kết nối có
  timeout 5 giây.

## Câu hỏi hay gặp

**`--mode light` dùng được trên VPS 1 GB không?**
Chạy được, ở khoảng 9 % hashrate (76 H/s so với 814 H/s). Đủ để giữ kết nối hoặc
thử cấu hình; muốn đào thật thì chọn VPS từ 2.5 GB trở lên.

**Bao nhiêu thread?**
`cache L3 / 2 MiB` đúng phần lớn trường hợp. Nếu VPS bị throttle, bớt một thread
rồi đo lại.

**Pool nội bộ có nên dùng TLS?**
Trên cùng máy hoặc trong mạng riêng, TLS tốn CPU mà không thêm bảo mật thật. Dùng
nó khi đi qua internet hoặc qua CDN.

**Đào được nhiều pool cùng lúc không?**
Được: nhiều cờ `-o`, hoặc nhiều phần tử trong `pools[]`. Nó thử theo thứ tự và
chuyển dự phòng sau `--retries` lần lỗi.

**API có làm miner chậm đi không?**
Không. Nó đọc các biến atomic được cập nhật mỗi giây và không bao giờ khoá worker.

**Bao lâu thì có share đầu tiên?**
Tuỳ độ khó pool: vài giây trên pool test, vài phút tới hàng giờ trên pool thật
với máy nhỏ. Share chậm không phải lỗi — kiểm tra hashrate và tìm dòng
`pool has been silent`.

**Làm sao biết miner đào đúng ví?**
`zmrig --check` in `user=…`, API trả `connection.pool`, và log khởi động in
`wallet: …`. Đối chiếu với dashboard của pool.

## Báo lỗi

```bash
zmrig --version
sudo ./oneclick.sh status
sudo ./oneclick.sh logs 80
sed 's/"user": *"[^"]*"/"user": "REDACTED"/' /etc/zmrig/config.json
```

Che ví và mọi token trước khi dán. Chỉ riêng log thường đã đủ nói lỗi nằm ở
transport, TLS hay ở chính pool.
