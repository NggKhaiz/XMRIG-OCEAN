# Giám sát: API và mã báo cáo

Có hai cách lấy số liệu ra khỏi miner, chọn theo nhu cầu:

| | API HTTP | Mã báo cáo |
|---|---|---|
| Dùng khi | máy trong cùng mạng/VPN, script, Prometheus | máy sau NAT, không mở cổng, dán vào web |
| Bảo mật | bind `127.0.0.1`, tuỳ chọn Bearer token | không mở cổng nào; bạn tự copy mã |
| Dữ liệu | đầy đủ, cập nhật từng giây | ảnh chụp tại thời điểm ghi |
| Nhiều máy | mỗi máy một endpoint | dán nhiều mã một lúc |

## API HTTP

Bật bằng `--http-port` (installer bật sẵn 18080):

```bash
curl -s 127.0.0.1:18080/1/summary
curl -s 127.0.0.1:18080/2/summary | python3 -m json.tool
```

Endpoint:

| Path | Nội dung |
|---|---|
| `/1/summary`, `/summary` | JSON gọn một dòng, cùng shape với XMRig |
| `/1/status` | trạng thái kết nối |
| `/2/summary`, `/2/status` | cùng dữ liệu, format nhiều dòng dễ đọc |
| `/json_rpc` | cùng `/1/summary` (tương thích client cũ) |

Bảo vệ bằng token:

```bash
zmrig ... --http-port 18080 --http-access-token "$TOKEN"
curl -s -H "Authorization: Bearer $TOKEN" 127.0.0.1:18080/1/summary
curl -s -H "$TOKEN" 127.0.0.1:18080/1/summary    # dạng trần cũng nhận
```

Thiếu token → `401` kèm JSON, path lạ → `404` kèm JSON. `HEAD` được hỗ trợ cho health check. Response có `Cache-Control: no-store`.

Ví dụ `/1/summary`:

```json
{"id":"zmrig","worker_id":"vps-sg-02","uptime":3600,"version":"6.26.0-mo9",
 "kind":"miner","ua":"zmrig/6.26.0-mo9","algo":"rx/0","paused":false,
 "donate_level":0,
 "connection":{"pool":"wss://relay.example.com:443","uptime":3600,"failures":0,"tls":true},
 "hashrate":{"total":[814.2,810.5,805.1],"highest":902.7},
 "hugepages":[1168,1168],"cpu":{"threads":2},
 "results":{"shares_good":42,"shares_total":42,"hashes_total":2931842,"error_log":[]}}
```

Lấy nhanh từ shell:

```bash
curl -s 127.0.0.1:18080/1/summary | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["hashrate"]["total"], d["results"]["shares_good"])'
```

Cảnh báo: API là **chỉ đọc**, không có endpoint đổi ví/restart. Đừng bind ra `0.0.0.0` nếu không có token và firewall — dù chỉ đọc, nó vẫn lộ tên máy, pool và ví worker của bạn.

## Sức khoẻ: máy còn kiếm tiền hay chỉ còn chạy?

Đây là câu hỏi khác với "service còn active không", và là chỗ tiền mất một cách im lặng: pool từ chối mọi share thì miner vẫn sống, vẫn kết nối, vẫn in hashrate — và thu nhập bằng 0.

Miner tự đánh giá mỗi giây và báo một trong năm trạng thái:

| Trạng thái | Nghĩa | Chuyện gì xảy ra |
|---|---|---|
| `warming` | đang build dataset, hoặc bạn tạm dừng | không làm gì (tạm dừng là tính năng) |
| `ok` | hashrate gần mức tốt nhất phiên này, có share được nhận | không làm gì |
| `degraded` | dưới 80% mức đỉnh trong 10 phút (nhiệt, hàng xóm ồn) | ghi cảnh báo |
| `stalled` | process sống nhưng không hash | ghi lỗi |
| `rejected` | có gửi share, pool không nhận cái nào | ghi lỗi |

```bash
sudo ./oneclick.sh status
#   hashrate: 1042.6 H/s (10s/60s/15m)
#   shares:   184/0/0 accepted
#   health:   ok
```

`stalled` hoặc `rejected` kéo dài **15 phút** thì process tự thoát với mã 3 — `Restart=always` biến nó thành lần khởi động sạch. Đánh đổi nói rõ: mất 16–30 giây hashrate thay vì mất vài giờ thu nhập bằng 0.

```bash
zmrig ... --no-health-restart     # không bao giờ tự thoát
zmrig ... --health-restart=1800   # lâu hơn mới bỏ cuộc (giây)
zmrig ... --health-warmup=300     # không xét gì trong 5 phút đầu
```

Trạng thái cũng nằm trong mã `ZMRIG1.` ở trường `"health"`, nên bảng nhiều máy có thể lọc đúng những máy "đang chạy nhưng không kiếm được gì".

## Mã báo cáo

Một lần đo, một dòng:

```bash
$ ./zmrig/out/zmrig --report --power 45
ZMRIG1.eyJ2IjoxLCJpZCI6InZwc...   # khoảng 380–520 ký tự
```

Mất khoảng 25–30 giây: 15–20 giây dựng dataset, 10 giây warm-up, 15 giây đo, rồi lấy mẫu công suất.
Nếu service đang chạy, dùng `sudo ./oneclick.sh report` — lệnh này tự dừng miner (nó đang giữ huge pages),
đo, rồi bật lại. Chạy tay khi service đang chạy thường bị OOM vì không còn đủ bộ nhớ cho dataset thứ hai. Hashrate trong mã là hashrate **ổn định** (cửa sổ 10 giây cuối), không phải trung bình cả lúc khởi động — nếu lấy trung bình, con số sẽ thấp hơn thực tế 20–25%.

Tuỳ chọn:

```bash
--report-time 30     # đo lâu hơn, số ổn định hơn
--report-id vps-hn   # tên máy trong báo cáo (mặc định lấy --rig-id)
--power 45           # công suất thực; không có thì thử RAPL/hwmon
```

Trong lúc đang đào, để miner tự cập nhật file:

```bash
--report-file /var/lib/xmrig-ocean/report.txt --report-interval 60
```

Installer bật sẵn mục này cho engine `zmrig`, nên sau khi cài chỉ cần:

```bash
sudo cat /var/lib/xmrig-ocean/report.txt
# ZMRIG1.eyJ2IjoxLCJpZCI6...
```

Hoặc một lệnh lấy mã có dừng/khởi động service tự động:

```bash
sudo ./oneclick.sh report --power 95
```

Mã chứa gì:

| Trường | Ý nghĩa |
|---|---|
| `id`, `cpu`, `cores`, `thr` | tên máy, model CPU, số core vật lý, số thread đào |
| `algo`, `mode` | thuật toán, `auto`/`fast`/`light` |
| `hs[0..3]` | hashrate 10 giây, 60 giây, 15 phút, cao nhất phiên |
| `hp` | huge page đã cấp / cần |
| `shares`, `hash`, `up` | share accepted, rejected, failed; tổng hash; thời gian chạy (giây) |
| `pw`, `pwsrc` | công suất (W) và nguồn: `rapl`/`hwmon` = package CPU, `user` = số đo ở ổ cắm, `none` = chưa có |
| `pool`, `ts`, `ver` | pool, thời điểm ghi, phiên bản miner |

Mã **không** chứa địa chỉ ví, token pool hay IP công khai. Nó là base64url của JSON — giải mã được bằng:

```bash
cat report.txt | cut -d. -f2 | tr '_-' '/+' | base64 -d | python3 -m json.tool
```

Mã còn có trường `"hw"` — số hash trên mỗi watt (hashrate cột 60 s chia công suất) khi đo được công suất, `null` khi không. Đây là con số chế độ `watt` tối ưu, nên nó nằm sẵn trong mã thay vì để mỗi người tự chia.

## Từ mã tới nhiều máy

1. Mỗi máy: `--report-id` khác nhau (hoặc `--rig-id`).
2. Bật `--report-file` trong config (installer làm sẵn).
3. `sudo cat /var/lib/xmrig-ocean/report.txt` → copy → dán vào bảng tính ở trang chủ, mỗi máy một dòng.
4. Bảng tính cộng tổng hashrate, W, kWh, tiền điện, doanh thu, lợi nhuận; xuất JSON để lưu hoặc chia sẻ.

Không có server trung gian nào. Nếu bạn cần giám sát liên tục 24/7, hãy lấy API về Prometheus/Netdata trong VPN nội bộ, đừng mở API ra Internet.

Tiếp: [Lợi nhuận](#loi-nhuan).
