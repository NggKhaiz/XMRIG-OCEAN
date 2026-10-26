# Giới thiệu

Đây là bản fork của XMRig (nhánh `6.26.0-mo9`) với hai điểm khác bản gốc:

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
