import Foundation

enum RemoteCollectorScript {
    /// Cross-platform collector (Linux + macOS). Prints one JSON object.
    static let source: String = #"""
import json, os, re, time, platform, subprocess, shutil

IS_DARWIN = platform.system() == "Darwin"

def read_text(path):
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            return f.read()
    except OSError:
        return ""

def sh(args, timeout=8):
    return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL, timeout=timeout)

def sh_ok(args, timeout=8):
    try:
        return sh(args, timeout=timeout)
    except Exception:
        return ""

def cpu_ticks():
    cores = os.cpu_count() or 1
    if IS_DARWIN:
        try:
            import ctypes
            from ctypes import Structure, c_uint32, c_int, byref, sizeof
            class host_cpu_load_info_data_t(Structure):
                _fields_ = [("cpu_ticks", c_uint32 * 4)]
            HOST_CPU_LOAD_INFO = 3
            libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
            host = libc.mach_host_self()
            info = host_cpu_load_info_data_t()
            count = c_int(sizeof(host_cpu_load_info_data_t) // sizeof(c_int))
            kr = libc.host_statistics(host, HOST_CPU_LOAD_INFO, byref(info), byref(count))
            if kr == 0:
                user, system, idle, nice = [int(x) for x in info.cpu_ticks]
                total = user + system + idle + nice
                return total, idle, int(cores)
        except Exception:
            pass
        # Fallback: kern.cp_time on older macOS
        raw = sh_ok(["sysctl", "-n", "kern.cp_time"]).strip()
        vals = [int(x) for x in raw.split() if x.isdigit()]
        if len(vals) >= 4:
            return sum(vals), vals[3], int(cores)
        return 0, 0, int(cores)
    line = ""
    for raw in read_text("/proc/stat").splitlines():
        if raw.startswith("cpu "):
            line = raw
            break
    parts = line.split()
    vals = [int(x) for x in parts[1:9]] if len(parts) >= 9 else [0] * 8
    total = sum(vals)
    idle = vals[3] if len(vals) > 3 else 0
    if cores <= 0:
        cores = sum(1 for l in read_text("/proc/cpuinfo").splitlines() if l.startswith("processor")) or 1
    return total, idle, int(cores)

def loadavg():
    try:
        return os.getloadavg()
    except OSError:
        pass
    if IS_DARWIN:
        raw = sh_ok(["sysctl", "-n", "vm.loadavg"]).strip()
        # { 1.23 1.45 1.67 }
        nums = re.findall(r"[\d.]+", raw)
        if len(nums) >= 3:
            return float(nums[0]), float(nums[1]), float(nums[2])
        return 0.0, 0.0, 0.0
    parts = read_text("/proc/loadavg").split()
    if len(parts) >= 3:
        return float(parts[0]), float(parts[1]), float(parts[2])
    return 0.0, 0.0, 0.0

def uptime_s():
    if IS_DARWIN:
        raw = sh_ok(["sysctl", "-n", "kern.boottime"])
        m = re.search(r"sec\s*=\s*(\d+)", raw)
        if m:
            return max(0, int(time.time()) - int(m.group(1)))
        return 0
    parts = read_text("/proc/uptime").split()
    try:
        return int(float(parts[0]))
    except Exception:
        return 0

def _parse_pages(vm_stat_text):
    page_size = 4096
    m = re.search(r"page size of\s+(\d+)\s+bytes", vm_stat_text)
    if m:
        page_size = int(m.group(1))
    pages = {}
    for line in vm_stat_text.splitlines():
        if ":" not in line:
            continue
        k, v = line.split(":", 1)
        num = re.sub(r"[^0-9]", "", v)
        if num:
            pages[k.strip()] = int(num)
    return page_size, pages

def _parse_swapusage(text):
    # total = 1024.00M  used = 200.00M  free = 824.00M
    def to_bytes(token):
        m = re.search(r"([\d.]+)([KMG]?)", token.replace(",", ""))
        if not m:
            return 0
        n = float(m.group(1))
        u = m.group(2)
        mult = {"": 1, "K": 1024, "M": 1024**2, "G": 1024**3}.get(u, 1)
        return int(n * mult)
    total = used = free = 0
    mt = re.search(r"total\s*=\s*([\d.]+[KMG]?)", text, re.I)
    mu = re.search(r"used\s*=\s*([\d.]+[KMG]?)", text, re.I)
    mf = re.search(r"free\s*=\s*([\d.]+[KMG]?)", text, re.I)
    if mt: total = to_bytes(mt.group(1))
    if mu: used = to_bytes(mu.group(1))
    if mf: free = to_bytes(mf.group(1))
    return total, used, free

def meminfo():
    if IS_DARWIN:
        try:
            total = int(sh(["sysctl", "-n", "hw.memsize"]).strip())
        except Exception:
            total = 0
        page_size, pages = _parse_pages(sh_ok(["vm_stat"]))
        free = pages.get("Pages free", 0)
        inactive = pages.get("Pages inactive", 0)
        speculative = pages.get("Pages speculative", 0)
        purgeable = pages.get("Pages purgeable", 0)
        # approximate available (similar to Activity Monitor pressure view, not exact)
        avail = (free + inactive + speculative + purgeable) * page_size
        avail = min(avail, total) if total else avail
        used = max(0, total - avail)
        pct = round((used * 100.0 / total), 1) if total else 0.0
        st, su, _sf = _parse_swapusage(sh_ok(["sysctl", "-n", "vm.swapusage"]))
        sp = round((su * 100.0 / st), 1) if st else 0.0
        return {
            "mem": {"total": total, "used": used, "available": avail, "percent": pct},
            "swap": {"total": st, "used": su, "percent": sp},
        }
    data = {}
    for line in read_text("/proc/meminfo").splitlines():
        if ":" not in line:
            continue
        k, rest = line.split(":", 1)
        num = rest.strip().split()[0]
        try:
            data[k] = int(num) * 1024
        except ValueError:
            pass
    total = data.get("MemTotal", 0)
    avail = data.get("MemAvailable")
    if avail is None:
        avail = data.get("MemFree", 0) + data.get("Buffers", 0) + data.get("Cached", 0) + data.get("SReclaimable", 0)
    used = max(0, total - avail)
    pct = round((used * 100.0 / total), 1) if total else 0.0
    st = data.get("SwapTotal", 0)
    sf = data.get("SwapFree", 0)
    su = max(0, st - sf)
    sp = round((su * 100.0 / st), 1) if st else 0.0
    return {
        "mem": {"total": total, "used": used, "available": avail, "percent": pct},
        "swap": {"total": st, "used": su, "percent": sp},
    }

def disk_root():
    # Prefer data volume on modern macOS if present
    mounts = ["/"]
    if IS_DARWIN:
        mounts = ["/System/Volumes/Data", "/"]
    for mount in mounts:
        try:
            st = os.statvfs(mount)
            if st.f_blocks <= 0:
                continue
            total = int(st.f_frsize * st.f_blocks)
            free = int(st.f_frsize * st.f_bavail)
            used = max(0, total - int(st.f_frsize * st.f_bfree))
            pct = round((used * 100.0 / total), 1) if total else 0.0
            return {"mount": mount, "total": total, "used": used, "free": free, "percent": pct}
        except OSError:
            continue
    return {"mount": "/", "total": 0, "used": 0, "free": 0, "percent": 0.0}

def net_bytes():
    out = {}
    if IS_DARWIN:
        # Prefer Link-level rows; byte counters are at fixed tail positions.
        text = sh_ok(["netstat", "-ib"])
        for line in text.splitlines()[1:]:
            cols = line.split()
            if len(cols) < 10:
                continue
            if not any(c.startswith("<Link") for c in cols):
                continue
            iface = cols[0].rstrip("*")
            try:
                # ... Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll
                rx = int(cols[-5])
                tx = int(cols[-2])
            except ValueError:
                continue
            out[iface] = {"rx": rx, "tx": tx}
        return out
    for line in read_text("/proc/net/dev").splitlines():
        if ":" not in line:
            continue
        iface, rest = line.split(":", 1)
        iface = iface.strip()
        cols = rest.split()
        if len(cols) < 9:
            continue
        try:
            out[iface] = {"rx": int(cols[0]), "tx": int(cols[8])}
        except ValueError:
            continue
    return out

def disk_bytes():
    if IS_DARWIN:
        text = sh_ok(["ioreg", "-c", "IOBlockStorageDriver", "-d", "1", "-r", "-w", "0"])
        read_b = sum(int(x) for x in re.findall(r'"Bytes \(Read\)"\s*=\s*(\d+)', text))
        write_b = sum(int(x) for x in re.findall(r'"Bytes \(Write\)"\s*=\s*(\d+)', text))
        return {"read": read_b, "write": write_b}
    read_b = 0
    write_b = 0
    for line in read_text("/proc/diskstats").splitlines():
        cols = line.split()
        if len(cols) < 14:
            continue
        name = cols[2]
        if name.startswith(("loop", "ram", "dm-", "sr")):
            continue
        if name[-1].isdigit() and not (
            name.startswith("nvme") and "p" not in name
            or name.startswith("mmcblk") and "p" not in name
            or name.startswith("md")
        ):
            if any(name.startswith(p) for p in ("sd", "vd", "xvd", "hd")):
                continue
            if "p" in name and name.startswith(("nvme", "mmcblk")):
                continue
        try:
            read_b += int(cols[5]) * 512
            write_b += int(cols[9]) * 512
        except ValueError:
            continue
    return {"read": read_b, "write": write_b}

def temp_c():
    if IS_DARWIN:
        # Best-effort; usually unavailable without privileged tools
        for cmd in (
            ["osx-cpu-temp"],
            ["/opt/homebrew/bin/osx-cpu-temp"],
            ["/usr/local/bin/osx-cpu-temp"],
        ):
            raw = sh_ok(cmd).strip()
            m = re.search(r"([\d.]+)", raw)
            if m:
                try:
                    v = float(m.group(1))
                    if -20 <= v <= 130:
                        return round(v, 1)
                except ValueError:
                    pass
        return None
    candidates = []
    hw = "/sys/class/hwmon"
    if os.path.isdir(hw):
        for name in sorted(os.listdir(hw)):
            base = os.path.join(hw, name)
            for fn in ("temp1_input", "temp2_input", "temp3_input"):
                candidates.append(os.path.join(base, fn))
    th = "/sys/class/thermal"
    if os.path.isdir(th):
        for name in sorted(os.listdir(th)):
            if name.startswith("thermal_zone"):
                candidates.append(os.path.join(th, name, "temp"))
    for path in candidates:
        raw = read_text(path).strip()
        if not raw:
            continue
        try:
            v = float(raw)
        except ValueError:
            continue
        if v > 200:
            v /= 1000.0
        if -20 <= v <= 130:
            return round(v, 1)
    return None

def top_procs(limit=12):
    items = []
    if IS_DARWIN:
        # -r sort by CPU; BSD ps
        out = sh_ok(["ps", "-Acr", "-o", "pid=,user=,%cpu=,rss=,comm="])
    else:
        try:
            out = sh(["ps", "-eo", "pid=,user=,%cpu=,rss=,comm=", "--sort=-%cpu"])
        except Exception:
            out = ""
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(None, 4)
        if len(parts) < 5:
            continue
        try:
            pid = int(parts[0])
            user = parts[1]
            cpu = float(parts[2])
            rss = int(float(parts[3])) * 1024
            name = parts[4]
        except ValueError:
            continue
        items.append({
            "pid": pid,
            "name": name[:64],
            "user": user,
            "cpu": round(cpu, 1),
            "rss": rss,
        })
        if len(items) >= limit:
            break
    return items

def find_docker_bin():
    candidates = []
    which = shutil.which("docker")
    if which:
        candidates.append(which)
    home = os.path.expanduser("~")
    candidates.extend([
        os.path.join(home, ".local/bin/docker"),
        "/opt/homebrew/bin/docker",
        "/usr/local/bin/docker",
        "/Applications/Docker.app/Contents/Resources/bin/docker",
        "/usr/bin/docker",
    ])
    seen = set()
    for path in candidates:
        if not path or path in seen:
            continue
        seen.add(path)
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return None

def docker_env():
    env = os.environ.copy()
    # Ensure common bins visible for child tools
    extras = [
        os.path.expanduser("~/.local/bin"),
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/Applications/Docker.app/Contents/Resources/bin",
    ]
    path = env.get("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
    for p in extras:
        if p and p not in path.split(":"):
            path = p + ":" + path
    env["PATH"] = path

    if env.get("DOCKER_HOST"):
        return env

    home = os.path.expanduser("~")
    socks = [
        os.path.join(home, ".docker/run/docker.sock"),
        "/var/run/docker.sock",
        os.path.join(home, ".colima/default/docker.sock"),
        os.path.join(home, ".colima/docker.sock"),
        "/run/user/%d/docker.sock" % (os.getuid(),),
    ]
    for sock in socks:
        try:
            if os.path.exists(sock):
                env["DOCKER_HOST"] = "unix://" + sock
                break
        except OSError:
            continue
    return env

def docker_status():
    info = {
        "available": False,
        "version": None,
        "error": None,
        "running": 0,
        "paused": 0,
        "stopped": 0,
        "containers": [],
    }
    docker = find_docker_bin()
    if not docker:
        info["error"] = "未找到 docker 命令（检查 PATH / Docker Desktop）"
        return info

    env = docker_env()

    def run(args, timeout=8):
        return subprocess.check_output(
            [docker] + args,
            text=True,
            stderr=subprocess.STDOUT,
            timeout=timeout,
            env=env,
        )

    try:
        ver = run(["version", "--format", "{{.Server.Version}}"], timeout=8).strip()
        info["available"] = True
        info["version"] = ver or None
    except Exception as e:
        err_out = e.output if isinstance(e, subprocess.CalledProcessError) else ""
        combined = (str(e) + " " + str(err_out)).lower()
        if "permission denied" in combined:
            info["error"] = "无权限访问 Docker socket"
        elif "cannot connect" in combined or "docker daemon" in combined or "is the docker daemon running" in combined:
            info["error"] = "无法连接 Docker（确认 Desktop/Colima 已启动）"
        elif "not found" in combined or "no such file" in combined:
            info["error"] = "未安装 docker"
        else:
            info["error"] = (str(err_out) or str(e))[:180].strip() or "docker 不可用"
        return info

    stats_by_id = {}
    stats_by_name = {}
    try:
        stats_out = run(["stats", "--no-stream", "--format", "{{json .}}"], timeout=15)
        for line in stats_out.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                s = json.loads(line)
            except Exception:
                continue
            cid = (s.get("ID") or s.get("Container") or "")[:12]
            name = (s.get("Name") or "").lstrip("/")
            entry = {
                "cpu": parse_pct(s.get("CPUPerc")),
                "mem_usage": s.get("MemUsage") or "",
                "mem_percent": parse_pct(s.get("MemPerc")),
                "net_io": s.get("NetIO") or "",
                "block_io": s.get("BlockIO") or "",
            }
            if cid:
                stats_by_id[cid] = entry
                # full id prefix match
                stats_by_id[cid[:12]] = entry
            if name:
                stats_by_name[name] = entry
    except Exception:
        pass

    try:
        ps_out = run(["ps", "-a", "--format", "{{json .}}"], timeout=10)
    except Exception as e:
        err_out = e.output if isinstance(e, subprocess.CalledProcessError) else str(e)
        info["error"] = str(err_out)[:180]
        return info

    containers = []
    for line in ps_out.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            c = json.loads(line)
        except Exception:
            continue
        full_id = c.get("ID") or ""
        cid = full_id[:12]
        name = str(c.get("Names") or "").split(",")[0].lstrip("/")
        state = (c.get("State") or "").lower()
        status = c.get("Status") or ""
        image = c.get("Image") or ""
        ports = c.get("Ports") or ""
        st = stats_by_id.get(cid) or stats_by_name.get(name) or {}
        # Docker Desktop stats ID may be short or long
        if not st:
            for k, v in stats_by_id.items():
                if k.startswith(cid) or cid.startswith(k):
                    st = v
                    break
        if state == "running":
            info["running"] += 1
        elif state == "paused":
            info["paused"] += 1
        else:
            info["stopped"] += 1
        containers.append({
            "id": cid,
            "name": name or cid,
            "image": image[:80],
            "state": state or "unknown",
            "status": status[:80],
            "ports": ports[:120] if isinstance(ports, str) else str(ports)[:120],
            "cpu": st.get("cpu"),
            "mem_percent": st.get("mem_percent"),
            "mem_usage": st.get("mem_usage") or "",
            "net_io": st.get("net_io") or "",
        })
    order = {"running": 0, "paused": 1, "restarting": 2, "created": 3, "exited": 4, "dead": 5}
    containers.sort(key=lambda x: (order.get(x["state"], 9), x["name"]))
    info["containers"] = containers[:50]
    return info

def parse_pct(v):
    if v is None:
        return None
    s = str(v).strip().rstrip("%")
    try:
        return round(float(s), 1)
    except ValueError:
        return None

total, idle, cores = cpu_ticks()
l1, l5, l15 = loadavg()
mem = meminfo()
payload = {
    "ts": int(time.time()),
    "uptime_s": uptime_s(),
    "os": "darwin" if IS_DARWIN else "linux",
    "load": {"l1": round(l1, 2), "l5": round(l5, 2), "l15": round(l15, 2)},
    "cpu": {"total": total, "idle": idle, "cores": cores},
    "mem": mem["mem"],
    "swap": mem["swap"],
    "disk": disk_root(),
    "net_bytes": net_bytes(),
    "disk_bytes": disk_bytes(),
    "temp_c": temp_c(),
    "top": top_procs(),
    "docker": docker_status(),
}
print(json.dumps(payload, separators=(",", ":")), flush=True)
"""#

    static func remoteCommand() -> String {
        let b64 = Data(source.utf8).base64EncodedString()
        // Expand PATH for Docker Desktop / Homebrew; macOS base64 uses -D/--decode
        return #"bash --noprofile --norc -c "export PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/Applications/Docker.app/Contents/Resources/bin:/usr/bin:/bin:$PATH\"; echo \#(b64) | (base64 --decode 2>/dev/null || base64 -D 2>/dev/null || base64 -d) | /usr/bin/env python3 -u""#
    }

    static func extractJSONObject(from raw: String) -> String? {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"),
              start <= end else {
            return nil
        }
        return String(raw[start...end])
    }
}
