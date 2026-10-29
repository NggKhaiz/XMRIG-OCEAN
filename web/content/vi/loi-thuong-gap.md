# Lỗi thường gặp

## Bảng chẩn đoán

| Hiện tượng | Nguyên nhân hay gặp | Cách xử lý |
|---|---|---|
| `dataset ready` mất 20–30 giây | bình thường: dựng 2 GiB | không phải lỗi; `--mode light` chỉ 0.6 giây nhưng hashrate còn 9% |
| Hashrate thấp hơn kỳ vọng 20–30% | huge pages không được cấp | `grep HugePages /proc/meminfo`; log phải ghi `huge pages 2336 MB` |
| Miner bị kill, exit 137 | hết RAM khi dựng dataset (thường do huge pages đang giữ chỗ) | bật huge pages cho đúng, hoặc dùng `--mode light` |
| `cannot read …: check the path or run as root` | config là file root-only | chạy bằng `sudo`, hoặc `chmod 600` và dùng sudo |
| `config ok` nhưng không đào | thiếu `-c` hoặc thiếu pool | `--check` chỉ kiểm tra file khi có `-c` |
| `login failed: …` lặp lại | sai ví/pool, pool chặn IP, TLS sai | xem log ngay sau dòng đó; thử `--transport tcp` để loại trừ TLS |
| `connection lost` liên tục | CDN/NAT cắt socket im lặng | `--keepalive-interval 60`, `--idle-timeout 120` |
| `share rejected: …` | difficulty/job cũ, đồng hồ máy lệch | kiểm tra NTP (`timedatectl`), xem thông báo cụ thể của pool |
| API trả 401 | có `access-token` | gửi `Authorization: Bearer TOKEN` |
| API không truy cập được từ máy khác | mặc định bind `127.0.0.1` | đừng mở ra Internet; dùng SSH tunnel |
| `--tls-ca` không có tác dụng | file nằm trong `/tmp`, unit dùng `PrivateTmp` | copy vào `/etc/xmrig-ocean/tls-ca.pem` |
| `verify` báo có chuỗi donate | bản cũ grep chữ "donate" | cập nhật repo; bản hiện tại chỉ grep endpoint/ví |
| Log file có ký tự `\x1b[` | bản cũ ghi nguyên dòng màu | đã sửa: file nhận text thuần, stdout vẫn có màu |
| `--background` không tách ra nền | bản cũ bỏ qua cờ | đã sửa; kiểm tra bằng `ps -o ppid= -p $(pgrep zmrig)` |
| Reconnect chậm 5 giây mỗi lần | bản cũ chờ `--retry-pause` cả khi phiên đã từng chạy | đã sửa: nối lại sau 200 ms, giãn dần khi lỗi liên tiếp |

## Những lỗi đã sửa trong 6.26.0-mo9 (để bạn không phải gặp lại)

- **`--background` bị bỏ qua** → miner vẫn chạy foreground. Giờ có `fork()` + `setsid` + đóng stdio.
- **Reconnect chậm và dồn dập** → chờ đủ `--retry-pause` sau mỗi lần rớt, và reset bộ đếm khi xoay pool nên pool chết bị đập liên tục. Giờ: nối lại ngay sau phiên đã login, 200 ms → 500 ms → 1 s → `--retry-pause`, bộ đếm không reset theo pool.
- **Log file lẫn mã màu ANSI** → file log giờ là text thuần.
- **Config bị cờ dòng lệnh ghi đè bằng giá trị mặc định** → `zmrig -c config.json --verbose` từng reset `mode`, `huge-pages`, `retries`… Giờ chỉ cờ thực sự gõ mới ghi đè.
- **`report.enabled` trong config từng bật chế độ `--report`** (đo rồi thoát) thay vì chỉ ghi file báo cáo. Đã tách hai việc.
- **`--check` bị bỏ qua khi có `-c`** trong một số tổ hợp → đã sửa.
- **Cờ `--tls` từng ngầm bật "không kiểm tra chứng chỉ"** → đã bỏ; `--tls` giờ chỉ chọn transport.
- **Dòng quá dài từ pool làm chết phiên** → giờ bỏ qua dòng đó và cảnh báo một lần khi phiên kết thúc.
- **`--http-port` không vào config** → đã sửa, installer ghi đúng boolean `enabled`.
- **Ctrl-C treo khi đang chờ login** → monitor đóng socket để main thread thoát ngay.
- **API thread bị treo bởi client mở socket rồi im lặng** → mỗi kết nối có timeout 5 giây.

## Câu hỏi hay gặp

**Có nên dùng `--mode light` cho VPS 1 GB RAM?**
Được, nhưng hashrate chỉ còn ~9% (76 H/s so với 814 H/s). Nếu chỉ để giữ kết nối hoặc thử cấu hình thì ổn; để đào thật thì nên chọn VPS có ≥2.5 GB RAM.

**Số thread tối ưu là bao nhiêu?**
Mặc định `L3 cache / 2 MiB` đã đúng trong đa số trường hợp. Nếu VPS bị throttle, thử giảm một thread và đo lại.

**Có nên bật TLS cho pool nội bộ?**
Nếu pool ở cùng máy/mạng riêng, TLS không thêm bảo mật thực chất mà tốn CPU. Dùng khi qua Internet hoặc qua CDN.

**Có thể chạy nhiều pool cùng lúc?**
Có: nhiều `-o` (hoặc nhiều mục trong `pools[]`). Miner thử lần lượt và failover sau `--retries` lần thất bại.

**API có làm chậm miner?**
Không. API chỉ đọc atomic đã cập nhật mỗi giây, không khoá worker.

**Bao lâu thì thấy share đầu tiên?**
Tuỳ difficulty pool. Với pool difficulty thấp (như test) là vài giây; với pool thật, vài phút đến vài giờ trên máy nhỏ. Share chậm không có nghĩa là hỏng — xem hashrate và `pool has been silent` trong log.

**Làm sao biết miner đang đào đúng ví?**
`zmrig --check` in `user=…`; API trả `connection.pool`; log lúc khởi động in `wallet: …`. Đối chiếu với ví trên dashboard pool.

## Khi cần báo lỗi

Kèm theo:

```bash
./zmrig/out/zmrig --version
sudo ./oneclick.sh status
sudo ./oneclick.sh logs 80
cat /etc/xmrig-ocean/config.json | sed 's/"user": *"[^"]*"/"user": "REDACTED"/'
```

Che ví và token trước khi dán lên đâu đó. Log thường đã đủ để thấy lỗi nằm ở transport, TLS hay pool.
