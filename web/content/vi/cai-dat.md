# Cài đặt

## Yêu cầu

- Linux x86-64 (Debian/Ubuntu, RHEL/Fedora, Arch đều được; script tự nhận distro).
- 2 GB RAM trống cho chế độ `fast` (dataset RandomX), hoặc dùng `--mode light` với ~300 MB.
- `systemd` nếu muốn cài như dịch vụ.
- Quyền root.

Script cần mạng để tải source (hoặc bạn clone sẵn repo). Không tải binary từ nơi khác: mọi thứ được biên dịch tại máy.

## Cài một lệnh

```bash
curl -fsSL https://raw.githubusercontent.com/NggKhaiz/ZMRIG/master/oneclick.sh \
  | sudo bash -s -- install \
      --wallet YOUR_WALLET \
      --pool gulf.moneroocean.stream:10001 \
      --engine zmrig
```

Nếu đã có repo:

```bash
sudo ./oneclick.sh install --wallet YOUR_WALLET --pool gulf.moneroocean.stream:10001 --engine zmrig
```

Script làm theo thứ tự: cài phụ thuộc (build-essential, cmake, libuv, …) → build engine hash + miner → tune hệ thống (huge pages, THP, governor, MSR) → viết `/etc/xmrig-ocean/config.json` → tạo systemd unit `xmrig-ocean` → self-check → in hashrate.

Toàn bộ idempotent: chạy lại không tạo service trùng, không ghi đè config trừ khi có `--force`, bỏ qua bước build nếu binary mới hơn source.

## Cờ thường dùng

| Cờ | Ý nghĩa |
|---|---|
| `--wallet ADDR` | địa chỉ ví hoặc login pool |
| `--pool HOST:PORT` | endpoint pool, mặc định `gulf.moneroocean.stream:10001` |
| `--pass VALUE` | password pool (mặc định `x`) |
| `--rig-id NAME` | tên máy hiện trên dashboard pool và trong mã báo cáo |
| `--algo NAME` | ép một thuật toán (mặc định pool tự chọn) |
| `--engine xmrig\|zmrig` | engine C++ hay engine Zig |
| `--tls` | dùng TLS cho kết nối pool |
| `--cloudflare[=HOST[:PORT]]` | pool qua `wss://` trên 443, tự chuyển sang engine `zmrig` |
| `--transport tcp\|tls\|ws\|wss` | ghi đè scheme của pool |
| `--ws-path PATH` | path WebSocket (mặc định `/`) |
| `--ws-origin URL` | header `Origin` cho upgrade |
| `--proxy URL` | `http://user:pass@host:port` hoặc `socks5://host:port` |
| `--connect-to HOST:PORT` | nối tới địa chỉ khác nhưng giữ SNI/`Host` của pool |
| `--tls-ca FILE` | tin CA riêng / pin chứng chỉ relay |
| `--idle-timeout N` | ngắt kết nối nếu pool im lặng N giây (0 = tắt) |
| `--power W` | công suất thực của máy, ghi vào mã báo cáo |
| `--report-file PATH` | nơi zmrig ghi mã báo cáo (mặc định `/var/lib/xmrig-ocean/report.txt`) |
| `--no-report` | không ghi file báo cáo |
| `--http-port PORT` | cổng API giám sát (mặc định 18080) |
| `--http-token TOKEN` | yêu cầu `Authorization: Bearer TOKEN` |
| `--no-http` | tắt API giám sát |
| `--cpu-hint N` | `max-threads-hint` phần trăm (mặc định 100) |
| `--no-tune` | bỏ qua bước chỉnh hệ thống |
| `--no-service` | cài và cấu hình nhưng không tạo service |
| `--force` | ghi đè config đang có |
| `--yes` | không hỏi gì |

Ví dụ cho VPS chỉ mở 443:

```bash
sudo ./oneclick.sh install \
  --wallet YOUR_WALLET \
  --pool my-relay.example.com \
  --cloudflare=my-relay.example.com --ws-path /pool \
  --power 45 --rig-id vps-sg-02
```

## Lấy mã báo cáo

```bash
sudo ./oneclick.sh report --power 95
# tạm dừng service, đo 15 giây, in ZMRIG1.…, rồi bật lại
```

Lệnh này cần engine `zmrig`. Nếu service đang chạy, nó tự dừng trước khi đo — dataset 2 GiB không thể dựng
hai lần cùng lúc. Mã in ra dán thẳng vào bảng tính trên trang chủ.

## Kiểm tra sau khi cài

```bash
./oneclick.sh status     # service, hashrate 10s/60s/15m, số share, huge pages
./oneclick.sh logs 50    # 50 dòng log cuối
curl -s 127.0.0.1:18080/1/summary | head -c 400
```

`status` chỉ đọc số thật: nếu miner vừa khởi động, nó in `warming up` thay vì hashrate của lần chạy trước, vì dataset cần 15–25 giây để dựng xong.

Trạng thái dịch vụ:

```bash
systemctl status xmrig-ocean
journalctl -u xmrig-ocean -f
```

Unit dùng `Restart=always`, `RestartSec=5`, `Nice=-10`, `LimitMEMLOCK=infinity`, `PrivateTmp=true`. Config chỉ root đọc được (`/etc/xmrig-ocean/config.json`, mode 600) vì có thể chứa token API.

## Cập nhật và gỡ

```bash
sudo ./oneclick.sh update      # git pull + build lại + restart
sudo ./oneclick.sh uninstall   # dừng, xoá service và binary (giữ config nếu bạn chọn giữ)
```

## Build tay (không dùng installer)

```bash
# engine hash + miner Zig
ZIG=/path/to/zig ./zmrig/build.sh --jobs 2

# kiểm tra
./zmrig/out/zmrig --self-test
./zmrig/out/zmrig --version

# chạy thử 60 giây
./zmrig/out/zmrig -o pool.example.com:3333 -u YOUR_WALLET -p x -t 2
```

Cần Zig 0.13.0 (bản 0.14 đổi API std, chưa build được) và `g++`, `ar`. Build ~35 giây trên 2 vCPU.

Engine C++ vẫn build bằng CMake như repo gốc:

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j2
```

Tiếp: [Cấu hình](#cau-hinh).
