# Kiểm thử

Ba bộ test, chạy được trên máy không cần pool thật.

## Self-test hash engine

```bash
./zmrig/out/zmrig --self-test          # đầy đủ, cần 2 GiB RAM
./zmrig/out/zmrig --self-test=light    # bỏ qua kiểm tra dataset
```

Kiểm tra: vector tham chiếu `rx/0`, hashing có pipelining, và dataset dựng từ cache cho cùng kết quả (full-memory). Đây là thứ `oneclick.sh verify` gọi trước khi kiểm tra phí.

## Bộ test API và hashing

```bash
./zmrig/tests/run.sh
```

Chạy self-test cộng thêm các case so sánh kết quả hash giữa cấu hình khác nhau (căn lề buffer, nhiều block, so sánh dataset) và kiểm tra API. Output cuối: `all API checks passed`.

## Bộ test mạng — 22 case

Dựng pool giả, TLS shim, proxy HTTP/SOCKS5 và WebSocket ngay trên máy bạn, rồi bắt miner nói chuyện với chúng:

```bash
./zmrig/tests/net.sh --quick     # cửa sổ 10 s mỗi case
./zmrig/tests/net.sh             # cửa sổ 18 s mỗi case
./zmrig/tests/net.sh --soak      # thêm 4 phút soak
./zmrig/tests/net.sh --only api,tcp
```

Danh sách case:

| Nhóm | Case | Kiểm chứng |
|---|---|---|
| Transport | `tcp`, `tls`, `ws`, `wss` | login, nhận job, submit share |
| | `ws path` | server nhận đúng path `/miner` |
| | `wss via socks5` | WebSocket + TLS chạy xuyên SOCKS5 |
| CDN | `cloudflare` | `wss` trên 443 với header `Host` đúng |
| | `cloudflare headers` | `Host` và path tới được edge |
| Proxy | `http proxy` / `http proxy target` | `CONNECT 127.0.0.1:4800` |
| | `socks5 proxy` / `socks5 proxy target` | auth + đích đúng |
| API | `http api` | summary phục vụ trên cổng 5009 |
| | `http api token` | request không token bị từ chối |
| | `http api 404` | path lạ bị từ chối |
| Lỗi | `login rejected` | lỗi hiện ra cho người dùng |
| | `idle watchdog` | tự nối lại sau 4 lần timeout |
| | `pool failover` | chuyển sang pool dự phòng |
| | `hostile pool` | sống sót với rác, vẫn submit share hợp lệ |
| | `hostile pool request` | mọi request gửi đi vẫn là JSON hợp lệ |
| Seed | `seed change` | dựng lại dataset 4 lần, vẫn đào tiếp |
| Soak | `soak` | 4 phút: đổi seed, đổi algo, rớt mạng đột ngột, đổi seed |

Thời gian thực tế phụ thuộc máy: bộ đầy đủ mất khoảng 12–15 phút trên 2 vCPU (mỗi case cần một share,
ở chế độ light là 50–70 H/s). Case `seed change` cần dựng lại dataset 2 GiB mỗi lần đổi seed (~20 giây),
nên trong chế độ `--quick` cửa sổ chạy là 90 giây chứ không phải 50.

Kết quả lần chạy gần nhất trên VM 2 vCPU:

```
22 passed, 0 failed, 0 skipped
```

Log từng case nằm trong `/tmp/zmrig-net.XXXXXX/` (đường dẫn in ở cuối). Khi một case fail, đọc file log của case đó trước: `cloudflare.log`, `shim-cf.log`, `pool.log`.

### Bẫy khi chạy test

- **Cổng bận.** Bộ test dùng 4800 (pool) và 4801–4813 (các shim). Một process cũ còn giữ cổng sẽ khiến case "cloudflare" fail với `accepted=0` trong khi log miner ghi `login ok`. Script giờ giết process lạ trước khi chạy và từ chối chạy nếu cổng 4800 bị process khác chiếm.
- **Huge pages.** Test chạy `--mode light` để không cần 2 GiB, nên hashrate khoảng 50–70 H/s. Đó là bình thường.
- **CPU bận.** Đừng chạy bench song song: sẽ OOM hoặc làm hỏng số đo.

## Kiểm tra 0% phí

```bash
sudo ./oneclick.sh verify
```

Với engine Zig: chạy self-test, rồi `strings` binary để tìm endpoint/ví donate đã biết. Với engine C++: chạy `scripts/verify-fee-free.sh`, script này còn kiểm tra `DONATE 0%` khi bị truyền `--donate-level=9`.

Điểm cần biết: `verify` grep **endpoint và ví**, không grep chữ "donate" — API giám sát trả `"donate_level": 0` một cách hợp pháp, grep chữ đó sẽ báo động giả. (Đã từng bị, đã sửa.)

## CI

`.github/workflows/test.yml` chạy build + safe hash suite trên Linux và macOS. Với engine Zig, thêm hai bước:

```yaml
      - name: zmrig self test
        run: ./zmrig/out/zmrig --self-test

      - name: zmrig network suite
        run: ./zmrig/tests/net.sh --quick
```

## Chạy test trên máy đang đào

Test mạng dùng cổng riêng và pool giả, không đụng miner thật. Nhưng nếu miner thật đang giữ huge pages, `--self-test` (bản đầy đủ) có thể không đủ RAM cho dataset kiểm tra. Dùng `--self-test=light`, hoặc `oneclick.sh stop` trước.

Tiếp: [Lỗi thường gặp](#loi-thuong-gap).
