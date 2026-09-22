# Ubuntu Status Panel (neoserver-like UI)

[中文](README.md)

A lightweight Web UI for monitoring Ubuntu CPU, memory, disk, network, I/O, temperature, and load, plus Top processes.

## Run (on an Ubuntu server)

```bash
sudo apt update
sudo apt install -y python3 python3-venv python3-pip

cd ubuntu-status-ui
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt

uvicorn app:app --host 0.0.0.0 --port 8899
```

Open in a browser: `http://<your-ubuntu-ip>:8899/`

## systemd (optional)

Copy `systemd/ubuntu-status-ui.service` to `/etc/systemd/system/`, adjust `WorkingDirectory` as needed, then:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now ubuntu-status-ui
sudo systemctl status ubuntu-status-ui --no-pager
```

## License

This project is licensed under the [GNU General Public License v2.0](LICENSE) (GPLv2).
