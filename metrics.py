from __future__ import annotations

import os
import time
from dataclasses import dataclass
from typing import Any

import psutil


def _read_first_existing(paths: list[str]) -> str | None:
    for p in paths:
        try:
            with open(p, "r", encoding="utf-8") as f:
                return f.read()
        except OSError:
            continue
    return None


def _get_temperature_c() -> float | None:
    # Prefer hwmon if present; fallback to thermal_zone.
    candidates: list[str] = []
    hwmon_root = "/sys/class/hwmon"
    if os.path.isdir(hwmon_root):
        for name in os.listdir(hwmon_root):
            base = os.path.join(hwmon_root, name)
            # common: temp1_input, temp2_input...
            for fn in ("temp1_input", "temp2_input", "temp3_input", "temp4_input"):
                candidates.append(os.path.join(base, fn))
    thermal_root = "/sys/class/thermal"
    if os.path.isdir(thermal_root):
        for name in os.listdir(thermal_root):
            if name.startswith("thermal_zone"):
                candidates.append(os.path.join(thermal_root, name, "temp"))

    raw = _read_first_existing(candidates)
    if not raw:
        return None
    try:
        v = float(raw.strip())
    except ValueError:
        return None

    # Many kernels report milli-Celsius.
    if v > 200:
        v = v / 1000.0
    if v < -20 or v > 130:
        return None
    return round(v, 1)


@dataclass
class _RateState:
    t: float
    net: dict[str, tuple[int, int]]  # iface -> (rx, tx) bytes
    disk: dict[str, tuple[int, int]]  # dev -> (read, write) bytes


class MetricsCollector:
    def __init__(self) -> None:
        t = time.time()
        self._state = _RateState(t=t, net=self._net_bytes(), disk=self._disk_bytes())
        # Warm up cpu percent so first call isn't 0/None
        psutil.cpu_percent(interval=None)

    def _net_bytes(self) -> dict[str, tuple[int, int]]:
        out: dict[str, tuple[int, int]] = {}
        for iface, c in psutil.net_io_counters(pernic=True).items():
            out[iface] = (int(c.bytes_recv), int(c.bytes_sent))
        return out

    def _disk_bytes(self) -> dict[str, tuple[int, int]]:
        out: dict[str, tuple[int, int]] = {}
        c = psutil.disk_io_counters(perdisk=True)
        if not c:
            return out
        for dev, v in c.items():
            out[dev] = (int(v.read_bytes), int(v.write_bytes))
        return out

    def _rates(self) -> dict[str, Any]:
        now = time.time()
        dt = max(0.25, now - self._state.t)

        net_now = self._net_bytes()
        disk_now = self._disk_bytes()

        def rate_map(
            cur: dict[str, tuple[int, int]],
            prev: dict[str, tuple[int, int]],
        ) -> dict[str, dict[str, float]]:
            res: dict[str, dict[str, float]] = {}
            for k, (a, b) in cur.items():
                pa, pb = prev.get(k, (a, b))
                res[k] = {
                    "in_bps": max(0.0, (a - pa) / dt),
                    "out_bps": max(0.0, (b - pb) / dt),
                }
            return res

        net_rates = rate_map(net_now, self._state.net)
        disk_rates = rate_map(disk_now, self._state.disk)

        self._state = _RateState(t=now, net=net_now, disk=disk_now)

        # Aggregate: ignore lo/virbr/docker* by default
        def is_real_iface(name: str) -> bool:
            return not (
                name == "lo"
                or name.startswith("docker")
                or name.startswith("br-")
                or name.startswith("veth")
                or name.startswith("virbr")
                or name.startswith("tailscale")
            )

        net_in = sum(v["in_bps"] for k, v in net_rates.items() if is_real_iface(k))
        net_out = sum(v["out_bps"] for k, v in net_rates.items() if is_real_iface(k))

        disk_in = sum(v["in_bps"] for v in disk_rates.values())
        disk_out = sum(v["out_bps"] for v in disk_rates.values())

        return {
            "net": {"in_bps": net_in, "out_bps": net_out, "pernic": net_rates},
            "disk": {"read_bps": disk_in, "write_bps": disk_out, "perdev": disk_rates},
            "dt": dt,
        }

    def top_processes(self, limit: int = 10) -> list[dict[str, Any]]:
        # cpu_percent is per-process since last call; use a short non-blocking refresh
        procs = []
        for p in psutil.process_iter(attrs=["pid", "name", "username"]):
            try:
                procs.append(p)
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                continue

        for p in procs:
            try:
                p.cpu_percent(interval=None)
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                pass

        time.sleep(0.1)

        items: list[dict[str, Any]] = []
        for p in procs:
            try:
                cpu = p.cpu_percent(interval=None)
                mem = p.memory_info().rss
                items.append(
                    {
                        "pid": p.pid,
                        "name": p.info.get("name") or "",
                        "user": p.info.get("username") or "",
                        "cpu": round(cpu, 1),
                        "rss": mem,
                    }
                )
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                continue

        items.sort(key=lambda x: (x["cpu"], x["rss"]), reverse=True)
        return items[:limit]

    def snapshot(self) -> dict[str, Any]:
        cpu = psutil.cpu_percent(interval=None)
        load1, load5, load15 = os.getloadavg() if hasattr(os, "getloadavg") else (0, 0, 0)

        vm = psutil.virtual_memory()
        sm = psutil.swap_memory()

        du = psutil.disk_usage("/")
        rates = self._rates()

        boot_ts = psutil.boot_time()
        now = time.time()
        uptime_s = int(now - boot_ts)

        return {
            "ts": int(now),
            "uptime_s": uptime_s,
            "load": {"l1": round(load1, 2), "l5": round(load5, 2), "l15": round(load15, 2)},
            "cpu": {"percent": round(cpu, 1), "cores": psutil.cpu_count(logical=True) or 0},
            "mem": {
                "total": int(vm.total),
                "used": int(vm.used),
                "free": int(vm.available),
                "percent": round(vm.percent, 1),
            },
            "swap": {"total": int(sm.total), "used": int(sm.used), "percent": round(sm.percent, 1)},
            "disk": {
                "mount": "/",
                "total": int(du.total),
                "used": int(du.used),
                "free": int(du.free),
                "percent": round(du.percent, 1),
            },
            "net": rates["net"],
            "io": rates["disk"],
            "temp_c": _get_temperature_c(),
        }
