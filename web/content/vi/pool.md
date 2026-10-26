# Tự dựng pool

Repo này có cả hai phía: miner (`zmrig`, `xmrig`) và một pool Monero viết bằng Node.js, không dependency, nằm trong `pool/`. Dựng pool riêng có nghĩa bạn giữ được phí pool thay vì trả cho người khác — và miner của bạn trỏ vào đó cũng chạy y như mọi pool khác.

## Phí 1% và vì sao

| Khoản | Giá trị |
|---|---|
| Phí pool | **1.0 %** mỗi block, trừ trước khi chia, làm tròn **xuống** |
| Phí ẩn | không có |
| Phí developer của miner | 0 % |
| Ngưỡng trả | 0.01 XMR, cộng vào phí mạng |

Phí được công bố ngay trong reply `login` (miner in ra), trong `/api/config` và trên trang trạng thái. Vì sao 1 %: các pool Monero lớn đang ở 0.6–1 %, và pool này làm thêm một việc mà phần lớn pool không làm — **băm lại từng share** bằng `zmrig --verify-share` trước khi trả tiền. Việc đó tốn CPU thật của người vận hành, và là thứ duy nhất khiến miner biết chắc không ai được trả cho công việc không làm.

## Chạy thử trong 5 phút

```bash
# 1. một node Monero (testnet cũng được khi mới dựng)
monerod --data-dir ~/.bitmonero --rpc-bind-ip 127.0.0.1 --confirm-external-bind

# 2. pool
cd pool
node src/index.js --check --config config.json   # kiểm tra cấu hình rồi thoát
node src/index.js --config config.json           # stratum + HTTP

# 3. miner, ở terminal khác
zmrig -o 127.0.0.1:3333 -u ĐỊA_CHỈ_VÍ.rig1 -t 4
```

Mở `http://127.0.0.1:8080/` để xem trang trạng thái; `curl -s 127.0.0.1:8080/api/stats` trả cùng số đó ở dạng JSON.

## Cần gì

* **Node.js ≥ 18.17** — không `npm install`, không database.
* **`monerod`** với JSON-RPC truy cập được.
* **`zmrig` trong `PATH`** để băm lại share. Không có nó, pool từ chối share thay vì tin tưởng mù:

  ```bash
  ./zmrig/build.sh --jobs 2
  sudo install -m 0755 zmrig/out/zmrig /usr/local/bin/zmrig
  ```

## Chia thưởng và bằng chứng

* Share chỉ được nhận khi hash pool tự tính trùng với hash miner gửi. Hash sai không chỉ bị từ chối: kết nối bị đóng.
* Trọng số share là **độ khó × thời gian**, không phải số share — mạng chậm không bị phạt, chia nhiều máy không bị trả đôi.
* Mỗi block được ghi vào `audit.jsonl`: thưởng, phí, từng khoản trả cho miner, và phần lẻ (dust) liệt kê riêng chứ không lặng lẽ cộng vào phí.

```bash
curl -s 127.0.0.1:8080/api/audit?limit=5 | python3 -m json.tool
curl -s 127.0.0.1:8080/api/worker/ĐỊA_CHỈ_VÍ
```

## Deploy miễn phí

| Nơi | Cách chạy | Ghi chú |
|---|---|---|
| Render | `render.yaml` (Docker) | một cổng, chỉ WebSocket; free instance ngủ sau 15 phút không có traffic |
| Fly.io | `fly.toml` + volume 1 GB | có TCP thật ở 3333; `monerod` không vừa máy 256 MB |
| Cloudflare Workers | `pool/worker/` | cầu WebSocket ⇄ TCP, không cần Durable Object |
| Vercel | chỉ trang tĩnh | function không giữ được kết nối stratum |

```bash
# Fly
fly launch --no-deploy --copy-config --dockerfile deploy/Dockerfile
fly volumes create pool_data --size 1
fly secrets set DAEMON=https://node.example:18081
fly deploy
```

Miner trỏ vào pool qua WebSocket (cần engine `zmrig`):

```bash
zmrig -o wss://pool.example.com/stratum -u ĐỊA_CHỈ_VÍ.rig1 -t 4
```

hoặc qua TCP nếu host mở cổng 3333:

```bash
zmrig -o pool.example.com:3333 -u ĐỊA_CHỈ_VÍ.rig1 -t 4
```

## Vận hành

* Giữ `state_file` trên volume. Không có nó, restart là mất số dư của miner.
* `/metrics` xuất Prometheus; `/healthz` trả 503 khi chưa có template từ `monerod`.
* Log audit chỉ ghi thêm — xoay vòng bằng `logrotate`, đừng sửa.
* Đổi ví phí bằng `OPERATOR_ADDRESS`; mặc định nằm trong `pool/src/operator.js`.
* `--check` từ chối những cấu hình không thể trả tiền đúng: phí ngoài 0–10 %, mode lạ, cửa sổ PPLNS quá ngắn.

Toàn bộ chi tiết (payout qua `monero-wallet-rpc`, API, bảo mật) nằm trong `pool/README.md`.
