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
    disks = disks_all()
    if not disks:
        return {"mount": "/", "total": 0, "used": 0, "free": 0, "percent": 0.0}
    # Primary = fullest
    return max(disks, key=lambda d: (d["percent"], d["total"]))

def disks_all():
    """List significant mounts (skip tiny/virtual)."""
    items = []
    seen = set()
    if IS_DARWIN:
        # APFS: "/" and "/System/Volumes/Data" share the same capacity — show only one.
        primary = None
        for mount in ("/System/Volumes/Data", "/"):
            try:
                st = os.statvfs(mount)
                if st.f_blocks <= 0:
                    continue
                total = int(st.f_frsize * st.f_blocks)
                free = int(st.f_frsize * st.f_bavail)
                used = max(0, total - int(st.f_frsize * st.f_bfree))
                if total < 100 * 1024 * 1024:
                    continue
                pct = round((used * 100.0 / total), 1) if total else 0.0
                primary = {"mount": mount, "total": total, "used": used, "free": free, "percent": pct}
                break
            except OSError:
                continue
        if primary:
            items.append(primary)
            seen.add(primary["mount"])
            seen.add("/")
            seen.add("/System/Volumes/Data")
        # External / removable volumes only
        try:
            for name in sorted(os.listdir("/Volumes")):
                mount = os.path.join("/Volumes", name)
                if not os.path.isdir(mount) or mount in seen:
                    continue
                # Skip firmlink / system synthetic volumes
                if name.startswith("com.apple.") or name in ("Macintosh HD",):
                    # "Macintosh HD" often firmlinks to system; skip if same size as primary
                    pass
                try:
                    st = os.statvfs(mount)
                    if st.f_blocks <= 0:
                        continue
                    total = int(st.f_frsize * st.f_blocks)
                    free = int(st.f_frsize * st.f_bavail)
                    used = max(0, total - int(st.f_frsize * st.f_bfree))
                    if total < 100 * 1024 * 1024:
                        continue
                    if primary and abs(total - primary["total"]) < 1024 * 1024 and abs(used - primary["used"]) < 1024 * 1024:
                        continue  # same APFS container / firmlink
                    pct = round((used * 100.0 / total), 1) if total else 0.0
                    items.append({"mount": mount, "total": total, "used": used, "free": free, "percent": pct})
                    seen.add(mount)
                except OSError:
                    continue
        except OSError:
            pass
        return items
    # Linux: /proc/mounts + statvfs is locale-proof; df is fallback only.
    skip_fs = {
        "tmpfs", "devtmpfs", "squashfs", "overlay", "overlay2", "aufs",
        "devpts", "cgroup", "cgroup2", "proc", "sysfs", "efivarfs", "autofs",
        "rpc_pipefs", "binfmt_misc", "tracefs", "debugfs", "securityfs",
        "pstore", "bpf", "hugetlbfs", "mqueue", "fuse", "fusectl",
        "fuse.portal", "fuse.gvfsd-fuse", "nsfs", "ramfs", "iso9660", "udf",
    }
    skip_prefix = (
        "/snap/", "/run/", "/sys/", "/proc/", "/dev/",
        "/var/lib/docker", "/var/lib/containers", "/var/lib/kubelet",
        "/var/lib/lxc", "/var/lib/lxd", "/boot/efi",
    )
    seen_dev = set()

    def consider(mount, fstype=""):
        fstype = (fstype or "").lower()
        if fstype and (fstype in skip_fs or fstype.startswith("fuse.")):
            return
        if not mount.startswith("/"):
            return
        if mount.startswith("/dev") or mount in ("/udev",):
            return
        if any(mount == p.rstrip("/") or mount.startswith(p) for p in skip_prefix):
            return
        if "/ram" in mount:
            return
        if mount in seen:
            return
        try:
            # Unescape /proc/mounts octal (e.g. \040)
            path = mount.encode("utf-8").decode("unicode_escape") if "\\" in mount else mount
            st = os.statvfs(path)
            if st.f_blocks <= 0:
                return
            total = int(st.f_frsize * st.f_blocks)
            free = int(st.f_frsize * st.f_bavail)
            used = max(0, total - int(st.f_frsize * st.f_bfree))
        except OSError:
            return
        if total < 100 * 1024 * 1024:
            return
        if path == "/boot" and total < 2 * 1024 * 1024 * 1024:
            return
        try:
            dev = os.stat(path).st_dev
            if dev in seen_dev:
                return
            seen_dev.add(dev)
        except OSError:
            pass
        seen.add(path)
        pct = round((used * 100.0 / total), 1) if total else 0.0
        items.append({"mount": path, "total": total, "used": used, "free": free, "percent": pct})

    for line in read_text("/proc/mounts").splitlines():
        parts = line.split()
        if len(parts) < 3:
            continue
        consider(parts[1], parts[2])

    if not items:
        # Fallback: LC_ALL=C df (avoid localized headers breaking column detect)
        text = (
            sh_ok(["env", "LC_ALL=C", "df", "-kP", "-T"])
            or sh_ok(["env", "LC_ALL=C", "df", "-kT"])
            or sh_ok(["env", "LC_ALL=C", "df", "-kP"])
            or sh_ok(["env", "LC_ALL=C", "df", "-k"])
            or sh_ok(["df", "-k"])
        )
        lines = [ln for ln in text.splitlines() if ln.strip()]
        prev = ""
        for line in lines[1:] if lines else []:
            parts = line.split()
            if len(parts) < 5:
                prev = (prev + " " + line).strip()
                continue
            if prev:
                parts = (prev + " " + line).split()
                prev = ""
            # Detect optional Type column: 2nd field non-numeric => fstype
            fstype = ""
            idx = 1
            if len(parts) >= 7:
                try:
                    int(parts[1])
                except ValueError:
                    fstype = parts[1]
                    idx = 2
            try:
                blocks, used_k, avail_k, usep = parts[idx], parts[idx + 1], parts[idx + 2], parts[idx + 3]
                mount = parts[-1]
                total = int(blocks) * 1024
                used = int(used_k) * 1024
                free = int(avail_k) * 1024
                pct = float(usep.replace("%", "") or 0)
            except (ValueError, IndexError):
                continue
            if fstype and (fstype.lower() in skip_fs or fstype.lower().startswith("fuse.")):
                continue
            if total < 100 * 1024 * 1024:
                continue
            if mount.startswith("/dev") or any(mount.startswith(p) for p in skip_prefix):
                continue
            if mount in seen:
                continue
            seen.add(mount)
            items.append({"mount": mount, "total": total, "used": used, "free": free, "percent": round(pct, 1)})

    data_disks = [d for d in items if d["mount"].startswith("/mnt/disk")]
    if data_disks:
        return data_disks
    items.sort(key=lambda d: (0 if d["mount"] == "/" else 1, d["mount"]))
    return items

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

def _parse_temp_raw(raw):
    raw = (raw or "").strip()
    if not raw:
        return None
    try:
        v = float(raw.split()[0])
    except ValueError:
        return None
    if v > 200:
        v /= 1000.0
    if -20 <= v <= 130:
        return round(v, 1)
    return None

def _hwmon_temp_inputs(base):
    paths = []
    for folder in (base, os.path.join(base, "device")):
        if not os.path.isdir(folder):
            continue
        try:
            names = os.listdir(folder)
        except OSError:
            continue
        for fn in sorted(names):
            if re.match(r"^temp\d+_input$", fn):
                paths.append(os.path.join(folder, fn))
    return paths

def temp_c():
    if IS_DARWIN:
        # Best-effort; usually unavailable without privileged tools.
        # smctemp reads SMC via private APIs and works on both Apple
        # Silicon and Intel without sudo; osx-cpu-temp is the legacy
        # Intel-only fallback.
        for cmd in (
            ["smctemp", "-c"],
            ["/opt/homebrew/bin/smctemp", "-c"],
            ["/usr/local/bin/smctemp", "-c"],
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
    cpu_names = (
        "coretemp", "k10temp", "k8temp", "zenpower", "cpu",
        "cpu_thermal", "soc_thermal", "x86_pkg_temp",
    )
    cpu_paths, other_paths = [], []
    hw = "/sys/class/hwmon"
    if os.path.isdir(hw):
        try:
            chips = sorted(os.listdir(hw))
        except OSError:
            chips = []
        for name in chips:
            base = os.path.join(hw, name)
            chip = read_text(os.path.join(base, "name")).strip().lower()
            inputs = _hwmon_temp_inputs(base)
            if chip in cpu_names or "coretemp" in chip or chip.startswith("k10"):
                cpu_paths.extend(inputs)
            else:
                other_paths.extend(inputs)
    thermal_paths = []
    th = "/sys/class/thermal"
    if os.path.isdir(th):
        try:
            zones = sorted(os.listdir(th))
        except OSError:
            zones = []
        for name in zones:
            if name.startswith("thermal_zone"):
                thermal_paths.append(os.path.join(th, name, "temp"))
    for path in cpu_paths + other_paths + thermal_paths:
        v = _parse_temp_raw(read_text(path))
        if v is not None:
            return v
    raw = sh_ok(["sensors", "-u"])
    for m in re.finditer(r"temp\d+_input:\s*([0-9.]+)", raw):
        v = _parse_temp_raw(m.group(1))
        if v is not None:
            return v
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

def find_openclaw_bin():
    found = shutil.which("openclaw")
    if found:
        return found
    home = os.path.expanduser("~")
    candidates = [
        os.path.join(home, ".local/node/bin/openclaw"),
        os.path.join(home, ".local/bin/openclaw"),
        "/opt/homebrew/bin/openclaw",
        "/usr/local/bin/openclaw",
    ]
    # npm global under ~/.local/node-*/bin
    local = os.path.join(home, ".local")
    try:
        for name in os.listdir(local):
            if name.startswith("node-"):
                p = os.path.join(local, name, "bin", "openclaw")
                candidates.append(p)
    except OSError:
        pass
    for p in candidates:
        try:
            if os.path.isfile(p) and os.access(p, os.X_OK):
                return p
        except OSError:
            continue
    return None

def openclaw_status():
    info = {
        "available": False,
        "error": None,
        "version": None,
        "update_channel": None,
        "gateway": None,
        "service": None,
        "sessions_count": 0,
        "default_model": None,
        "agents": [],
        "tasks": None,
        "channels": [],
        "recent_sessions": [],
    }
    claw = find_openclaw_bin()
    if not claw:
        info["error"] = "未安装 openclaw"
        return info

    try:
        out = subprocess.check_output(
            [claw, "status", "--json"],
            text=True,
            stderr=subprocess.STDOUT,
            timeout=12,
            env=os.environ.copy(),
        )
    except subprocess.TimeoutExpired:
        info["error"] = "openclaw status 超时"
        return info
    except Exception as e:
        err_out = ""
        if isinstance(e, subprocess.CalledProcessError):
            err_out = e.output or ""
        msg = (str(err_out) or str(e))[:180].strip()
        info["error"] = msg or "openclaw 不可用"
        return info

    raw = out.strip()
    # CLI may print warnings before JSON
    start = raw.find("{")
    end = raw.rfind("}")
    if start < 0 or end <= start:
        info["error"] = "无法解析 openclaw status JSON"
        return info
    try:
        data = json.loads(raw[start:end + 1])
    except Exception:
        info["error"] = "openclaw status JSON 无效"
        return info

    info["available"] = True
    info["version"] = data.get("runtimeVersion") or None
    info["update_channel"] = data.get("updateChannel") or None

    gw = data.get("gateway") or {}
    if isinstance(gw, dict):
        self_info = gw.get("self") if isinstance(gw.get("self"), dict) else {}
        info["gateway"] = {
            "mode": gw.get("mode") or "",
            "url": gw.get("url") or "",
            "reachable": bool(gw.get("reachable")),
            "misconfigured": bool(gw.get("misconfigured")),
            "latency_ms": gw.get("connectLatencyMs"),
            "host": (self_info or {}).get("host") or "",
            "ip": (self_info or {}).get("ip") or "",
            "version": (self_info or {}).get("version") or info["version"] or "",
            "error": gw.get("error"),
        }

    svc = data.get("gatewayService") or {}
    if isinstance(svc, dict):
        runtime = svc.get("runtime") if isinstance(svc.get("runtime"), dict) else {}
        info["service"] = {
            "label": svc.get("label") or "",
            "installed": bool(svc.get("installed")),
            "loaded": bool(svc.get("loaded")),
            "status": (runtime or {}).get("status") or "",
            "state": (runtime or {}).get("state") or "",
            "pid": (runtime or {}).get("pid"),
            "short": svc.get("runtimeShort") or "",
        }

    sessions = data.get("sessions") or {}
    if isinstance(sessions, dict):
        info["sessions_count"] = int(sessions.get("count") or 0)
        defaults = sessions.get("defaults") if isinstance(sessions.get("defaults"), dict) else {}
        info["default_model"] = (defaults or {}).get("model") or None
        recent = sessions.get("recent") or []
        items = []
        if isinstance(recent, list):
            for s in recent[:8]:
                if not isinstance(s, dict):
                    continue
                key = str(s.get("key") or "")
                # shorten key for UI: keep last segment
                short_key = key.split(":")[-1] if key else (s.get("sessionId") or "")[:12]
                items.append({
                    "agent_id": s.get("agentId") or "",
                    "key": short_key[:64],
                    "kind": s.get("kind") or "",
                    "model": s.get("model") or "",
                    "age_ms": s.get("age"),
                    "percent_used": s.get("percentUsed"),
                    "total_tokens": s.get("totalTokens"),
                    "aborted": bool(s.get("abortedLastRun")),
                })
        info["recent_sessions"] = items

    agents_block = data.get("agents") or {}
    agents_list = []
    if isinstance(agents_block, dict):
        for a in (agents_block.get("agents") or []):
            if not isinstance(a, dict):
                continue
            agents_list.append({
                "id": a.get("id") or "",
                "sessions": int(a.get("sessionsCount") or 0),
                "last_active_ms": a.get("lastActiveAgeMs"),
                "bootstrap_pending": bool(a.get("bootstrapPending")),
            })
    info["agents"] = agents_list

    tasks = data.get("tasks") or {}
    if isinstance(tasks, dict):
        by_status = tasks.get("byStatus") if isinstance(tasks.get("byStatus"), dict) else {}
        info["tasks"] = {
            "total": int(tasks.get("total") or 0),
            "active": int(tasks.get("active") or 0),
            "failures": int(tasks.get("failures") or 0),
            "running": int((by_status or {}).get("running") or 0),
            "queued": int((by_status or {}).get("queued") or 0),
            "succeeded": int((by_status or {}).get("succeeded") or 0),
            "failed": int((by_status or {}).get("failed") or 0),
        }

    channels = []
    for ch in (data.get("channelSummary") or []):
        if isinstance(ch, str):
            channels.append({"name": ch[:80], "status": ""})
        elif isinstance(ch, dict):
            name = ch.get("name") or ch.get("id") or ch.get("channel") or ch.get("label") or ""
            status = ch.get("status") or ch.get("state") or ch.get("summary") or ""
            channels.append({"name": str(name)[:80], "status": str(status)[:80]})
    info["channels"] = channels[:20]
    return info

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
    "disks": disks_all(),
    "net_bytes": net_bytes(),
    "disk_bytes": disk_bytes(),
    "temp_c": temp_c(),
    "top": top_procs(),
    "docker": docker_status(),
    "openclaw": openclaw_status(),
}
print(json.dumps(payload, separators=(",", ":")), flush=True)
"""#

    static func remoteCommand() -> String {
        let b64 = Data(source.utf8).base64EncodedString()
        // Expand PATH for Docker Desktop / Homebrew / OpenClaw; macOS base64 uses -D/--decode
        return #"bash --noprofile --norc -c "export PATH=\"$HOME/.local/node/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/Applications/Docker.app/Contents/Resources/bin:/usr/bin:/bin:$PATH\"; PY=\$(command -v python3 || command -v python || true); if [ -z \"\$PY\" ]; then echo '{\"error\":\"未找到 python3/python\"}'; exit 1; fi; echo \#(b64) | (base64 --decode 2>/dev/null || base64 -D 2>/dev/null || base64 -d) | \"\$PY\" -u""#
    }

    /// Short remote wrapper: run Python with script on stdin (avoids huge argv on old SSHD).
    static var pythonStdinRemoteCommand: String {
        #"export PATH="$HOME/.local/node/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/Applications/Docker.app/Contents/Resources/bin:/usr/bin:/bin:$PATH"; PY=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true); if [ -z "$PY" ]; then echo '{"error":"no python"}'; exit 42; fi; exec "$PY" -u -"#
    }

    /// POSIX sh collector for ancient Linux (no python3 / tiny ARG_MAX). Emits the same JSON shape.
    static let legacyShellSource: String = #"""
set +e
export PATH="/bin:/usr/bin:/sbin:/usr/sbin:/usr/local/bin:$PATH"
DF_BIN=$(command -v df 2>/dev/null || ls /bin/df /usr/bin/df 2>/dev/null | head -1)
PS_BIN=$(command -v ps 2>/dev/null || ls /bin/ps /usr/bin/ps 2>/dev/null | head -1)
AWK_BIN=$(command -v awk 2>/dev/null || ls /bin/awk /usr/bin/awk /usr/bin/gawk 2>/dev/null | head -1)
SED_BIN=$(command -v sed 2>/dev/null || ls /bin/sed /usr/bin/sed 2>/dev/null | head -1)
HEAD_BIN=$(command -v head 2>/dev/null || ls /bin/head /usr/bin/head 2>/dev/null | head -1)
TR_BIN=$(command -v tr 2>/dev/null || ls /bin/tr /usr/bin/tr 2>/dev/null | head -1)
[ -n "$HEAD_BIN" ] || HEAD_BIN=head
[ -n "$SED_BIN" ] || SED_BIN=sed
[ -n "$TR_BIN" ] || TR_BIN=tr

UP=0
if [ -r /proc/uptime ]; then
  read UP _ignore < /proc/uptime
  UP=${UP%%.*}
fi
L1=0; L5=0; L15=0
read L1 L5 L15 ignore < /proc/loadavg 2>/dev/null || true
CPU_LINE=$(grep '^cpu ' /proc/stat 2>/dev/null | $HEAD_BIN -1)
CPU_TOTAL=0; CPU_IDLE=0; CORES=1
if [ -n "$CPU_LINE" ]; then
  set -- $CPU_LINE
  shift
  CPU_IDLE=$4
  CPU_TOTAL=0
  for v in "$@"; do CPU_TOTAL=$((CPU_TOTAL + v)); done
fi
CORES=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)
[ "$CORES" -gt 0 ] 2>/dev/null || CORES=1
MEM_TOTAL=0; MEM_AVAIL=0; MEM_FREE=0; BUFF=0; CACHE=0; SWAP_T=0; SWAP_F=0
while read key val rest; do
  case "$key" in
    MemTotal:) MEM_TOTAL=$val ;;
    MemAvailable:) MEM_AVAIL=$val ;;
    MemFree:) MEM_FREE=$val ;;
    Buffers:) BUFF=$val ;;
    Cached:) CACHE=$val ;;
    SwapTotal:) SWAP_T=$val ;;
    SwapFree:) SWAP_F=$val ;;
  esac
done < /proc/meminfo 2>/dev/null
MEM_TOTAL_KB=$MEM_TOTAL; MEM_AVAIL_KB=$MEM_AVAIL; MEM_FREE_KB=$MEM_FREE
BUFF_KB=$BUFF; CACHE_KB=$CACHE; SWAP_T_KB=$SWAP_T; SWAP_F_KB=$SWAP_F
# BusyBox ash is 32-bit: never multiply large KB in $(( )); use awk.
kb2b() {
  if [ -n "$AWK_BIN" ]; then
    $AWK_BIN -v k="${1:-0}" 'BEGIN{printf "%.0f", (k+0)*1024}'
  else
    echo $((${1:-0} * 1024))
  fi
}
MEM_TOTAL=$(kb2b "$MEM_TOTAL_KB")
MEM_AVAIL=$(kb2b "$MEM_AVAIL_KB")
MEM_FREE=$(kb2b "$MEM_FREE_KB")
BUFF=$(kb2b "$BUFF_KB")
CACHE=$(kb2b "$CACHE_KB")
SWAP_T=$(kb2b "$SWAP_T_KB")
SWAP_F=$(kb2b "$SWAP_F_KB")
if [ "${MEM_AVAIL_KB:-0}" -eq 0 ] 2>/dev/null; then
  MEM_AVAIL_KB=$((MEM_FREE_KB + BUFF_KB + CACHE_KB))
  MEM_AVAIL=$(kb2b "$MEM_AVAIL_KB")
fi
MEM_USED_KB=$((MEM_TOTAL_KB - MEM_AVAIL_KB))
[ "$MEM_USED_KB" -lt 0 ] 2>/dev/null && MEM_USED_KB=0
MEM_USED=$(kb2b "$MEM_USED_KB")
MEM_PCT=0
SWAP_U_KB=$((SWAP_T_KB - SWAP_F_KB))
[ "$SWAP_U_KB" -lt 0 ] 2>/dev/null && SWAP_U_KB=0
SWAP_U=$(kb2b "$SWAP_U_KB")
SWAP_PCT=0
if [ -n "$AWK_BIN" ]; then
  [ "$MEM_TOTAL_KB" -gt 0 ] 2>/dev/null && MEM_PCT=$($AWK_BIN -v u="$MEM_USED_KB" -v t="$MEM_TOTAL_KB" 'BEGIN{printf "%.1f", (u*100)/t}')
  [ "$SWAP_T_KB" -gt 0 ] 2>/dev/null && SWAP_PCT=$($AWK_BIN -v u="$SWAP_U_KB" -v t="$SWAP_T_KB" 'BEGIN{printf "%.1f", (u*100)/t}')
fi

# --- disks: all significant mounts (BusyBox df -k); also set primary disk ---
DISK_T=0; DISK_U=0; DISK_A=0; DISK_P=0; DISK_M="/"
DISKS_JSON=""
if [ -n "$DF_BIN" ] && [ -n "$AWK_BIN" ]; then
  EVAL=$($DF_BIN -k 2>/dev/null | $AWK_BIN '
    function to_b(k) { return sprintf("%.0f", (k+0)*1024) }
    NR==1 { next }
    {
      if (NF < 5) { prev=$0; next }
      if (prev != "") { $0 = prev " " $0; prev="" }
      mount=$NF
      pct=$(NF-1); sub(/%/, "", pct)
      avail=$(NF-2); used=$(NF-3); total=$(NF-4)
      if (total+0 < 100*1024) next
      if (mount ~ /^\/dev/ || mount == "/udev") next
      if (mount ~ /ram/ || mount == "/dev") next
      if (mount == "/boot" && total+0 < 2*1024*1024) next
      tb=to_b(total); ub=to_b(used); ab=to_b(avail)
      n++
      mounts[n]=mount; pcts[n]=pct; tots[n]=tb; useds[n]=ub; avails[n]=ab
      if (mount ~ /^\/mnt\/disk/) data++
      if (pct+0 > bestpct+0 || (pct+0==bestpct+0 && total+0 > besttot+0)) {
        bestpct=pct+0; besttot=total+0; bi=n
      }
    }
    END {
      if (n < 1) exit
      # If NAS-style /mnt/disk* exists, only emit those
      use_data = (data > 0)
      first=1
      printf "["
      besti=0; bestp=-1
      for (i=1; i<=n; i++) {
        if (use_data && mounts[i] !~ /^\/mnt\/disk/) continue
        if (pcts[i]+0 > bestp) { bestp=pcts[i]+0; besti=i }
        if (!first) printf ","
        first=0
        printf "{\"mount\":\"%s\",\"total\":%s,\"used\":%s,\"free\":%s,\"percent\":%s}", mounts[i], tots[i], useds[i], avails[i], pcts[i]
      }
      printf "]\n"
      if (besti == 0) besti = bi
      printf "PRIMARY %s %s %s %s %s\n", pcts[besti], tots[besti], useds[besti], avails[besti], mounts[besti]
    }
  ')
  # Lines: [json...] then PRIMARY ...
  DISKS_JSON=$(echo "$EVAL" | $SED_BIN -n '1p')
  PRIMARY=$(echo "$EVAL" | $SED_BIN -n '2p')
  if [ -n "$PRIMARY" ]; then
    set -- $PRIMARY
    shift
    DISK_P=$1; DISK_T=$2; DISK_U=$3; DISK_A=$4; shift 4; DISK_M=$*
  fi
fi
if [ -z "$DISKS_JSON" ] || [ "$DISKS_JSON" = "[]" ]; then
  if [ -n "$DF_BIN" ]; then
    DFONE=$($DF_BIN -k / 2>/dev/null | $SED_BIN '1d' | $TR_BIN '\n' ' ' | $TR_BIN -s ' ')
    set -- $DFONE
    while [ $# -ge 5 ]; do
      case "$1" in *[!0-9]*) shift ;; *) break ;; esac
    done
    if [ $# -ge 5 ]; then
      DISK_T=$(kb2b "$1"); DISK_U=$(kb2b "$2"); DISK_A=$(kb2b "$3")
      DISK_P=$(echo "$4" | $TR_BIN -d '%'); shift 4; DISK_M=$1
    fi
  fi
  DISKS_JSON="[{\"mount\":\"$DISK_M\",\"total\":$DISK_T,\"used\":$DISK_U,\"free\":$DISK_A,\"percent\":$DISK_P}]"
fi
[ -z "$DISK_P" ] && DISK_P=0
case "$DISK_P" in *[!0-9.]*|"") DISK_P=0 ;; esac
[ -z "$DISK_M" ] && DISK_M="/"

DISK_READ=0; DISK_WRITE=0
if [ -r /proc/diskstats ] && [ -n "$AWK_BIN" ]; then
  DW=$($AWK_BIN '
    {
      name=$3
      if (name ~ /^(loop|ram|dm-|sr)/) next
      if (name ~ /^sd[a-z]$/ || name ~ /^hd[a-z]$/ || name ~ /^vd[a-z]$/ || name ~ /^md[0-9]+$/) {
        r+=$6; w+=$10
      }
    }
    END { printf "%.0f %.0f", r*512, w*512 }
  ' /proc/diskstats 2>/dev/null)
  set -- $DW
  DISK_READ=${1:-0}
  DISK_WRITE=${2:-0}
fi

# --- top: BusyBox 1.7 ps only supports `ps` / `ps w` (no aux / -eo) ---
TOP_JSON=""
if [ -n "$PS_BIN" ]; then
  # BusyBox: PID USER VSZ STAT COMMAND  (or PID Uid VmSize Stat Command)
  PS_RAW=$($PS_BIN w 2>/dev/null)
  [ -z "$PS_RAW" ] && PS_RAW=$($PS_BIN 2>/dev/null)
  if [ -n "$PS_RAW" ] && [ -n "$AWK_BIN" ]; then
    PS_OUT=$(echo "$PS_RAW" | $AWK_BIN '
      NR==1 && ($1 ~ /PID/ || $1 == "PID") { next }
      {
        pid=$1+0; if (pid<=0) next
        user=$2
        vsz=$3+0
        # STAT may be $4; command from $5 or $4 if numeric-less
        cmd=$5; start=5
        if ($4 ~ /^[0-9]+$/) { vsz=$4+0; cmd=$5; start=5 }
        for (i=start+1; i<=NF; i++) cmd=cmd " " $i
        if (cmd=="") cmd=$4
        n=split(cmd, a, "/"); name=a[n]
        if (name=="") name="?"
        gsub(/["\\]/, "", name); gsub(/["\\]/, "", user)
        # Sort key: VSZ desc (no CPU on BusyBox ps)
        printf "%010d %s %s %s %s\n", vsz, pid, user, vsz, name
      }
    ' | sort -nr 2>/dev/null | $HEAD_BIN -12)
  elif [ -n "$PS_RAW" ]; then
    PS_OUT=$(echo "$PS_RAW" | $SED_BIN '1d' | $HEAD_BIN -12 | while read pid user vsz stat cmd rest; do
      echo "0 $pid $user $vsz $cmd"
    done)
  fi
  if [ -n "$PS_OUT" ]; then
    while IFS= read -r pline; do
      [ -z "$pline" ] && continue
      set -- $pline
      # formats: "vszkey pid user vsz name..." or "cpu pid user rss name..."
      case "$1" in
        *[!0-9]*) continue ;;
      esac
      # If 5+ fields from busybox sorted line: skip sort key
      if [ $# -ge 5 ]; then
        # detect 010-padded sort key (10 digits)
        case "$1" in
          [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9])
            shift
            ;;
        esac
      fi
      cpu=0; pid=$1; user=$2; rss=$3; shift 3
      name=$*
      case "$pid" in *[!0-9]*|"") continue ;; esac
      case "$rss" in *[!0-9]*|"") rss=0 ;; esac
      rss_b=$(kb2b "$rss")
      [ -n "$TOP_JSON" ] && TOP_JSON="$TOP_JSON,"
      TOP_JSON="$TOP_JSON{\"pid\":$pid,\"name\":\"$name\",\"user\":\"$user\",\"cpu\":$cpu,\"rss\":$rss_b}"
    done <<EOF
$PS_OUT
EOF
  fi
fi

NET_JSON=""
if [ -r /proc/net/dev ]; then
  while IFS= read -r line; do
    case "$line" in
      *:*)
        iface=${line%%:*}
        iface=$(echo "$iface" | $TR_BIN -d ' ')
        case "$iface" in
          lo|LO) continue ;;
        esac
        rest=${line#*:}
        set -- $rest
        rx=$1; tx=$9
        case "$rx" in *[!0-9]*|"") rx=0 ;; esac
        case "$tx" in *[!0-9]*|"") tx=0 ;; esac
        [ -n "$NET_JSON" ] && NET_JSON="$NET_JSON,"
        NET_JSON="$NET_JSON\"$iface\":{\"rx\":$rx,\"tx\":$tx}"
        ;;
    esac
  done < /proc/net/dev
fi
[ -z "$NET_JSON" ] && NET_JSON="\"eth0\":{\"rx\":0,\"tx\":0}"

# --- temperature (sysfs milli-Celsius); prefer CPU hwmon then any sensor ---
TEMP_C=null
if [ -n "$AWK_BIN" ]; then
  TEMP_C=$(
    {
      for d in /sys/class/hwmon/hwmon*; do
        [ -r "$d/name" ] || continue
        n=$(cat "$d/name" 2>/dev/null)
        case "$n" in
          coretemp|k10temp|k8temp|zenpower|cpu|cpu_thermal|soc_thermal|x86_pkg_temp)
            for f in "$d"/temp*_input; do
              [ -r "$f" ] || continue
              cat "$f" 2>/dev/null
            done
            ;;
        esac
      done
      for f in /sys/class/hwmon/hwmon*/temp*_input /sys/class/thermal/thermal_zone*/temp; do
        [ -r "$f" ] || continue
        cat "$f" 2>/dev/null
      done
    } 2>/dev/null | $AWK_BIN '
      NF>=1 {
        v=$1+0
        if (v>200) v=v/1000
        if (v>=-20 && v<=130) { printf "%.1f", v; ok=1; exit }
      }
      END { if (!ok) printf "null" }
    '
  )
  [ -n "$TEMP_C" ] || TEMP_C=null
fi
TS=$(date +%s 2>/dev/null || echo 0)
printf '{"ts":%s,"uptime_s":%s,"load":{"l1":%s,"l5":%s,"l15":%s},"cpu":{"total":%s,"idle":%s,"cores":%s},"mem":{"total":%s,"used":%s,"available":%s,"percent":%s},"swap":{"total":%s,"used":%s,"percent":%s},"disk":{"mount":"%s","total":%s,"used":%s,"free":%s,"percent":%s},"disks":%s,"net_bytes":{%s},"disk_bytes":{"read":%s,"write":%s},"temp_c":%s,"top":[%s],"docker":{"available":false,"version":null,"error":"legacy collector","running":0,"paused":0,"stopped":0,"containers":[]},"openclaw":{"available":false,"error":"legacy collector","version":null,"update_channel":null,"gateway":null,"service":null,"sessions_count":0,"default_model":null,"agents":[],"tasks":null,"channels":[],"recent_sessions":[]}}\n' \
  "$TS" "$UP" "$L1" "$L5" "$L15" "$CPU_TOTAL" "$CPU_IDLE" "$CORES" \
  "$MEM_TOTAL" "$MEM_USED" "$MEM_AVAIL" "$MEM_PCT" \
  "$SWAP_T" "$SWAP_U" "$SWAP_PCT" \
  "$DISK_M" "$DISK_T" "$DISK_U" "$DISK_A" "$DISK_P" \
  "$DISKS_JSON" \
  "$NET_JSON" "$DISK_READ" "$DISK_WRITE" "$TEMP_C" "$TOP_JSON"
"""#

    static var legacyShellRemoteCommand: String {
        #"export PATH="/bin:/usr/bin:/sbin:/usr/sbin:$PATH"; /bin/sh -s"#
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
