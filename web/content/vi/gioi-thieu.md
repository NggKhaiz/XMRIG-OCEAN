# Giới thiệu

**ZMRIG** là bộ công cụ đào Monero do **[@nggkhaiz](https://github.com/NggKhaiz)** làm và giữ: miner (hai engine), installer một lệnh, proxy cho cả farm, pool tự dựng, và website bạn đang đọc. Giấy phép GPL-3.0, không có phí developer, không tracking.

Phần lõi hash là XMRig — một fork của XMRig (nhánh `6.26.0-mo9`) với hai điểm khác bản gốc:

1. **Không có phí developer.** Không ví donate, không chiến lược donate, không endpoint donate trong binary.
2. **Có thêm engine `zmrig`** viết bằng Zig, nói được WebSocket/TLS trên cổng 443, HTTP CONNECT và SOCKS5 — tức là chạy được trên VPS chỉ mở HTTPS, sau CDN hoặc sau proxy công ty.

Engine C++ (`xmrig`) vẫn còn nguyên: mọi thuật toán, mọi backend, hành vi như bản gốc. Engine Zig chỉ làm RandomX nhưng làm đúng phần khó: transport cho mạng kén chọn, API giám sát nhỏ, mã báo cáo để tính điện.

## Hai engine, chọn cái nào?

| | `xmrig` (C++) | `zmrig` (Zig) |
|---|---|---|
| Thuật toán | tất cả (34+) | `rx/0`, `rx/2`, `rx/wow`, `rx/arq`, `rx/graft`, `rx/sfx`, `rx/yada`, `panthera` |
| Transport | TCP, TLS | TCP, TLS, `ws`, `wss` |
| Proxy | SOCKS5 một phần | HTTP CONNECT + SOCKS5 (có auth, DNS từ xa) |
| API giám sát | có (đầy đủ) | có (đọc, tương thích XMRig) |
| Mã báo cáo cho dashboard | không | có (`--report`) |
| Hiệu năng `rx/0` | ~1075 H/s (đo trên VM 2 vCPU) | ~1008–1103 H/s cùng máy, cùng cấu hình |

Con số hiệu năng ngang nhau vì cả hai dùng chung engine hash RandomX trong repo này (`zmrig/capi/`). Khác biệt nằm ở phần mạng và vận hành, không phải ở vòng lặp hash.

Nếu chỉ cần đào `rx/0` trên VPS bình thường: engine nào cũng được, `zmrig` nhẹ hơn và có dashboard. Nếu cần algo khác RandomX: dùng `xmrig`.

## 0% phí nghĩa là gì

Miner không tự đổi ví, không tự kết nối endpoint lạ, không "mượn" CPU theo chu kỳ. Bằng chứng kiểm tra được:

```bash
sudo ./oneclick.sh verify
# ==> verifying zmrig
#     OK PASS rx/0 reference vector
#     OK PASS pipelined hashing
#     OK PASS full-memory dataset matches the cache
#     OK no donation endpoints or wallets: 0% developer fee
#     OK verified
```

Script grep binary để tìm endpoint và ví donate (`donate.v2.xmrig.com`, `xmrig.com/donate`, các địa chỉ ví đã biết), rồi chạy self-test hash. Với engine C++ nó chạy `scripts/verify-fee-free.sh`, script này còn kiểm tra `DONATE 0%` khi bị truyền `--donate-level=9`.

Phần còn lại của phí pool (thường 0–1%) do pool quy định, không liên quan đến repo này.

## Ủng hộ dự án

Miner không lấy phí, nên câu trả lời thật thà cho câu "ủng hộ thế nào?" là: không cần đâu. Ai vẫn muốn gửi thì chỉ có **một** địa chỉ, và nó nằm ở đây. Không có flag, khoá config hay service nào đọc địa chỉ này — `sudo ./oneclick.sh verify` vẫn ra `0% developer fee` dù địa chỉ có nằm trong repo.

![QR địa chỉ Monero donate](assets/donate-monero.png)

```text
46SQLW7DXaq6GJaQbHUFMAhd1VYpfQFJQ2gfZo9TCB8bf9vnf1MUwAD2Fwj6KMsY4RU3oKA3x6hByg8BKg7FfMWn6ysb5tJ
```

- **Chỉ XMR**, mạng chính, địa chỉ chuẩn 95 ký tự (network byte `18`), checksum base58 hợp lệ. Gửi BTC/ETH/USDT là mất tiền.
- **Cùng ví với phí 1% của pool.** `pool/src/operator.js` giải mã ra đúng địa chỉ này, và mỗi instance đang chạy công bố nó ở `/api/config`. Một ví, một sổ cái.
- **Kiểm tra trước khi gửi:** bắt đầu bằng `46SQLW7D`, kết thúc bằng `n6ysb5tJ`, dài đúng 95 ký tự. Công thức kiểm tra checksum bằng Python nằm trong [`doc/DONATE.md`](https://github.com/NggKhaiz/ZMRIG/blob/BETA/doc/DONATE.md).
- **Donate không mua gì cả:** không có bản "supporter" nhanh hơn, không ưu tiên hỗ trợ, không badge, không thuê bao. Nếu ai đó bán "bản build nhanh hơn" thì không phải dự án này.
- **Địa chỉ khác đều không phải của dự án.** Chỉ chuỗi ở trên là thật; địa chỉ trong fork, issue, video hay tin nhắn riêng đều không phải.

Nếu không muốn gửi tiền, ba việc sau có giá trị hơn: đào qua pool (phí 1% mới nuôi được công việc), gửi một phép đo trước/sau bằng `zmrig/tests/ab.sh`, hoặc mở issue kèm lệnh và output đầy đủ.

## Repo có gì

```
oneclick.sh              cài đặt, cấu hình, service, verify, update, uninstall
zmrig/src/*.zig          engine Zig: main, options, stratum, transport, miner, api_http, report
zmrig/capi/              cầu nối C++ cho engine RandomX + shim
pool/                    pool Monero tự dựng: stratum TCP + WebSocket, PPLNS, verify share
zmrig/tests/             self-test, bộ test mạng (22 case), benchmark
doc/                     tài liệu kỹ thuật: NETWORK, PERFORMANCE, INSTALL, ALTERNATIVES, ZERO_FEE
web/                     website này (tĩnh, deploy được lên Cloudflare Pages / Vercel)
src/                     XMRig gốc, đã bỏ phần donate
```

## Điều trang này không hứa

- Không hứa "lợi nhuận cao nhất thị trường". Đào Monero bằng CPU thường lỗ hoặc hoà so với tiền điện; bảng tính ở trang chủ cho bạn thấy đúng con số đó thay vì tô hồng.
- Không hứa hashrate tuyệt đối. Cùng một binary, cùng một VPS, host khác nhau có thể lệch 20–30%. Mọi so sánh trong tài liệu là **tương đối**.
- Không hứa chạy được trên mọi thứ. Engine Zig cần Linux x86-64 (ARM64 build được nhưng chưa test), RandomX JIT cần x86-64/ARM64/RISCV64. Trên kiến trúc khác, RandomX rơi xuống interpreter và chậm hơn nhiều — đó là giới hạn của RandomX, không phải của miner.

Tiếp: [Cài đặt](#cai-dat).

## Tác giả và giấy phép

| | |
|---|---|
| Tác giả | [@nggkhaiz](https://github.com/NggKhaiz) — mã nguồn, installer, proxy, pool, website |
| Giấy phép | GPL-3.0 ([`LICENSE`](https://github.com/NggKhaiz/ZMRIG/blob/BETA/LICENSE)) |
| Ghi công | [`NOTICE`](https://github.com/NggKhaiz/ZMRIG/blob/BETA/NOTICE) — XMRig, RandomX, MoneroOcean, Monero Project, và các thư viện đi kèm |
| Mã nguồn | <https://github.com/NggKhaiz/ZMRIG> (nhánh `BETA` là bản dùng) |
| Báo lỗi | <https://github.com/NggKhaiz/ZMRIG/issues> — kèm lệnh, output đầy đủ và phần cứng |
| Ủng hộ | không cần; nếu muốn thì có đúng một địa chỉ ở [trang chủ](index.html#ung-ho) |
