# Cấu hình

## Thứ tự ưu tiên

1. Cờ dòng lệnh.
2. File `-c/--config`.
3. Mặc định của miner.

Một điểm dễ nhầm: **chỉ cờ bạn thực sự gõ mới ghi đè config**. Chạy `zmrig -c config.json --verbose` không làm mất `"mode": "light"` hay `"huge-pages": false` trong file. (Bản trước 6.26.0-mo9 thì có — xem CHANGELOG, mục Fixes.)

## File cấu hình do installer sinh ra

```json
{
  "api": { "id": null, "worker-id": "vps-sg-02" },
  "http": {
    "enabled": true,
    "host": "127.0.0.1",
    "port": 18080,
    "access-token": null,
    "restricted": true
  },
  "autosave": true,
  "background": false,
  "colors": false,
  "randomx": {
    "mode": "auto",
    "rdmsr": true,
    "wrmsr": true,
    "numa": true,
    "scratchpad_prefetch_mode": 1
  },
  "cpu": {
    "huge-pages": true,
    "huge-pages-jit": true,
    "priority": 5,
    "max-threads-hint": 100,
    "asm": true
  },
  "donate-level": 0,
  "pools": [
    {
      "algo": null,
      "url": "gulf.moneroocean.stream:10001",
      "user": "YOUR_WALLET",
      "pass": "x",
      "rig-id": "vps-sg-02",
      "keepalive": true,
      "enabled": true,
      "tls": false,
      "transport": "wss",
      "ws-path": "/pool"
    }
  ],
  "print-time": 60,
  "retries": 5,
  "retry-pause": 5,
  "idle-timeout": 300,
  "keepalive-interval": 60,
  "report": { "enabled": true, "file": "/var/lib/xmrig-ocean/report.txt", "interval": 60 },
  "power": 45
}
```

Các khoá `transport`, `ws-path`, `ws-origin`, `proxy`, `connect-to`, `tls-ca`, `idle-timeout`, `keepalive-interval`, `report`, `power` chỉ engine Zig hiểu; engine C++ bỏ qua khoá lạ, nên cùng một file dùng được cho cả hai.

## Khoá config engine Zig

| Khoá | Kiểu | Mặc định | Ghi chú |
|---|---|---|---|
| `algo` | string | tự chọn | `rx/0`, `rx/wow`, `panthera`, … |
| `print-time` | số | 60 | giây giữa hai dòng hashrate, 0 = tắt |
| `retries` | số | 5 | số lần thử mỗi pool trước khi failover |
| `retry-pause` | số | 5 | giây giữa hai lần thử |
| `idle-timeout` | số | 300 | pool im lặng quá lâu thì ngắt, 0 = tắt |
| `keepalive-interval` | số | 60 | giây giữa hai `keepalived` |
| `colors` | bool | true | màu log (file log luôn là text thuần) |
| `background` | bool | false | fork vào nền |
| `log-file` | string | null | ghi thêm log ra file |
| `power` | số | — | công suất đo ở ổ cắm (W), đưa vào mã báo cáo |
| `report.file` | string | null | nơi ghi mã báo cáo |
| `report.interval` | số | 60 | giây giữa hai lần ghi |
| `report.id` | string | `rig-id` | tên máy trong báo cáo |
| `http.enabled` | bool | false | bật API giám sát |
| `http.port` / `http.host` | số / string | 18080 / 127.0.0.1 | |
| `http.access-token` | string | null | yêu cầu Bearer token |
| `randomx.mode` | `auto`/`fast`/`light` | auto | `fast` = dataset 2 GiB |
| `cpu.threads` | số / mảng | cache-aware | mảng = mỗi phần tử một thread |
| `cpu.huge-pages` | bool | true | |
| `cpu.huge-pages-jit` | bool | true | |
| `cpu.asm` | bool | true | JIT (tắt = chậm ~6 lần) |
| `cpu.priority` | số | -1 | thang XMRig 1..5 hoặc nice thô |

Khoá trong `pools[]`: `url`, `user`, `pass`, `rig-id`, `algo`, `keepalive`, `tls`, `transport`, `ws-path`, `ws-origin`, `host-header`, `connect-to`, `tls-ca`, `proxy`, `enabled`.

## Cờ dòng lệnh của `zmrig`

### Mạng

```
-o, --url=URL            tcp|tls|ws|wss, ví dụ wss://pool.example.com/monero
-u, --user=USER          ví hoặc login
-p, --pass=PASS          password (mặc định x)
-a, --algo=ALGO          rx/0, rx/2, rx/wow, rx/arq, rx/graft, rx/sfx, rx/yada, panthera
                         'auto' khai toàn bộ họ RandomX để pool trả theo coin đắt nhất
                         có thể chuyển rig sang (MoneroOcean) thay vì giữ rig ở rx/0
    --rig-id=ID          tên máy gửi pool
    --keepalive / --no-keepalive
    --transport=NAME     tcp | tls | ws | wss
    --cloudflare[=HOST]  wss://HOST:443/ (preset cho mạng chỉ mở HTTPS)
    --ws-path=PATH       path WebSocket
    --ws-origin=URL      header Origin
    --tls                TLS cho pool hiện tại
    --tls-ca=FILE        tin CA trong FILE
    --tls-insecure       nhận cho tương thích; chưa bật (xem ghi chú)
    --connect-to=H:P     nối địa chỉ khác, giữ SNI/Host
    --proxy=URL          http://user:pass@host:port hoặc socks5://host:port
    --retries=N          số lần thử mỗi pool (5)
    --retry-pause=N      giây giữa hai lần thử (5)
    --idle-timeout=N     ngắt nếu pool im lặng N giây (300, 0 = tắt)
    --keepalive-interval=N  (60, 0 = tắt)
```

### Đào

```
-t, --threads=N          số thread (mặc định theo L3 cache)
    --mode=auto|fast|light
    --no-huge-pages
    --no-huge-pages-jit
    --no-jit
    --no-affinity
    --priority=N         1..5 (XMRig) hoặc nice thô, ví dụ -10
    --scratchpad-prefetch=N  0 nop, 1 prefetcht0 (mặc định), 2 prefetchnta, 3 load
    --no-optimized-init  dùng bộ khởi tạo dataset di động
```

### Log và vận hành

```
    --no-color
    --verbose
    --print-time=N       giây giữa hai dòng hashrate (60, 0 = tắt)
    --log-file=FILE      ghi thêm log
    --background         fork vào nền (log file vẫn ghi)
-c, --config=FILE
    --check              kiểm tra cấu hình rồi thoát
    --self-test[=light]  kiểm tra engine hash
    --bench[=HASHES]     đo hashrate
    --report             đo 15 giây rồi in mã báo cáo
    --report-time=N      thời gian đo của --report (15)
    --report-file=FILE   cập nhật FILE khi đang đào
    --report-interval=N  giây giữa hai lần ghi (60)
    --report-id=NAME     tên máy trong báo cáo
    --power=W            công suất thực (W)
    --http-port=N        cổng API
    --http-host=ADDR     địa chỉ bind (127.0.0.1)
    --http-access-token=TOKEN
-h, --help
-V, --version
```

## Hai chế độ: `free` và `watt`

```bash
sudo ./oneclick.sh install --wallet YOUR_WALLET --profile free   # hashrate tối đa
sudo ./oneclick.sh install --wallet YOUR_WALLET --profile watt   # tối đa H/W
sudo ./oneclick.sh install --wallet YOUR_WALLET                  # = auto
```

`auto` đọc trạng thái pin: laptop đang dùng pin → `watt`, còn lại → `free`.

Cùng một config, hai khoá khác nhau:

```json
{
    "profile": "watt",
    "cpu": {
        "threads": 6
    }
}
```

`"profile"` do miner đọc lúc khởi động, nên rút sạc rồi restart service là máy tự
chuyển sang chế độ tiết kiệm điện. `"threads"` là kết quả đo của
`--autotune` (installer chạy một lần sau khi build); xoá khoá này là quay về
heuristic `L3 / 2 MiB`.

## Đổi thread

Mặc định là `L3 cache / 2 MiB`, không vượt quá số CPU logic. Trên VPS 2 vCPU / 54 MB L3, mặc định là 2 thread và đó cũng là mức tốt nhất — đo được 814 H/s với 2 thread và 408 H/s với 1 thread. Chỉ đặt `-t` khi:

- bạn muốn chừa CPU cho việc khác (`-t 1`);
- VPS có nhiều vCPU nhưng L3 nhỏ (mặc định đã xử lý);
- bạn biết mình đang làm gì với affinity.

Không đoán nữa — để máy tự đo:

```bash
zmrig --autotune=8        # không cần pool, mỗi ứng viên 8 s
#   threads     hashrate  verdict
#         1   499.625 H/s  best so far
#         2   999.750 H/s  best so far
# best: 2 thread(s) at 999.750 H/s
# autotune-best-threads=2
```

Chênh lệch dưới 2% bị coi là nhiễu, nên nó không đổi thread chỉ vì một lần đo
may mắn.

## Kiểm tra cấu hình trước khi chạy

```bash
sudo ./zmrig/out/zmrig -c /etc/xmrig-ocean/config.json --check
# config ok
#   pool    wss://my-relay.example.com:443/pool user=4Ad... algo=auto
#   route   connect 10.0.0.7:443, Host: my-relay.example.com
#   proxy   socks5 127.0.0.1:1080
#   threads 2 (default would be 2)
#   mode    auto, huge pages on, jit on
```

Lệnh này chỉ đọc file và in ra; không mở socket, không cấp phát dataset. Nếu file là root-only, phải chạy bằng `sudo` — nếu không bạn sẽ nhận `cannot read …: check the path or run as root`.

Tiếp: [Benchmark và tinh chỉnh](#hieu-nang).
