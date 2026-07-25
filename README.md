# Ubuntu 状态面板（类似 neoserver 的图形界面）

一个轻量 Web UI，用来查看 Ubuntu 的 CPU/内存/磁盘/网络/I/O/温度/负载，并展示 Top 进程。

## 运行（在 Ubuntu 服务器上）

```bash
sudo apt update
sudo apt install -y python3 python3-venv python3-pip

cd ubuntu-status-ui
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt

uvicorn app:app --host 0.0.0.0 --port 8899
```

浏览器访问：`http://<你的ubuntu-ip>:8899/`

## systemd（可选）

把 `systemd/ubuntu-status-ui.service` 放到 `/etc/systemd/system/`，按需修改 `WorkingDirectory`，然后：

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now ubuntu-status-ui
sudo systemctl status ubuntu-status-ui --no-pager
```
