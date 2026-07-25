const el = (id) => document.getElementById(id);

function clamp(n, a, b) {
  return Math.max(a, Math.min(b, n));
}

function fmtBytes(n) {
  if (n == null) return "-";
  const units = ["B", "KiB", "MiB", "GiB", "TiB"];
  let v = Math.max(0, Number(n));
  let i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  const digits = v >= 100 ? 0 : v >= 10 ? 1 : 2;
  return `${v.toFixed(digits)} ${units[i]}`;
}

function fmtBps(n) {
  if (n == null) return "-";
  return `${fmtBytes(n)}/s`;
}

function fmtPct(n) {
  if (n == null || Number.isNaN(Number(n))) return "-";
  return `${Number(n).toFixed(1)}%`;
}

function fmtUptime(sec) {
  if (sec == null) return "-";
  const s = Math.max(0, sec | 0);
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  return d > 0 ? `${d}天 ${h}小时` : `${h}小时 ${m}分钟`;
}

function setGauge(gaugeEl, percent, color) {
  const p = clamp(Number(percent) || 0, 0, 100);
  const deg = (p / 100) * 360;
  const c = color || "var(--blue)";
  gaugeEl.style.background = `conic-gradient(${c} 0deg ${deg}deg, rgba(148,163,184,.15) ${deg}deg 360deg)`;
}

function barPct(value, max) {
  const p = max <= 0 ? 0 : clamp((value / max) * 100, 0, 100);
  return `${p.toFixed(0)}%`;
}

let netPeak = { up: 1, down: 1 };

async function fetchJSON(url) {
  const r = await fetch(url, { cache: "no-store" });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  return await r.json();
}

function renderTop(items) {
  const body = el("top-body");
  body.innerHTML = "";
  for (const it of items) {
    const row = document.createElement("div");
    row.className = "tr";
    row.innerHTML = `
      <div class="td pid">${it.pid}</div>
      <div class="td name">${(it.name || "").replaceAll("<", "&lt;")}</div>
      <div class="td user">${(it.user || "").replaceAll("<", "&lt;")}</div>
      <div class="td cpu">${it.cpu?.toFixed ? it.cpu.toFixed(1) : it.cpu}</div>
      <div class="td mem">${fmtBytes(it.rss)}</div>
    `;
    body.appendChild(row);
  }
}

async function refreshTop() {
  try {
    const data = await fetchJSON("/api/top?limit=10");
    renderTop(data.items || []);
  } catch (e) {
    // ignore
  }
}

async function tick() {
  try {
    const m = await fetchJSON("/api/metrics");
    el("subtitle").textContent = "在线";

    // Header chips
    el("chip-uptime").textContent = `Uptime: ${fmtUptime(m.uptime_s)}`;
    el("chip-load").textContent = `Load: ${m.load?.l1 ?? "-"} / ${m.load?.l5 ?? "-"} / ${m.load?.l15 ?? "-"}`;
    el("chip-temp").textContent = `温度: ${m.temp_c == null ? "-" : `${m.temp_c}°C`}`;

    // CPU
    const cpuPct = m.cpu?.percent ?? 0;
    el("cpu-percent").textContent = fmtPct(cpuPct);
    el("cpu-cores").textContent = `${m.cpu?.cores ?? "-"} 线程`;
    el("cpu-text").textContent = fmtPct(cpuPct);
    el("cpu-load").textContent = `load1 ${m.load?.l1 ?? "-"}`;
    el("ts").textContent = new Date((m.ts || Date.now() / 1000) * 1000).toLocaleTimeString();
    setGauge(el("cpu-gauge"), cpuPct, cpuPct > 85 ? "var(--red)" : cpuPct > 60 ? "var(--amber)" : "var(--blue)");

    // Memory
    const memPct = m.mem?.percent ?? 0;
    el("mem-percent").textContent = fmtPct(memPct);
    el("mem-text").textContent = `${fmtBytes(m.mem?.used)} / ${fmtBytes(m.mem?.total)}`;
    el("mem-used").textContent = fmtBytes(m.mem?.used);
    el("mem-avail").textContent = fmtBytes(m.mem?.free);
    el("mem-free").textContent = `可用 ${fmtBytes(m.mem?.free)}`;
    el("swap-used").textContent = `${fmtBytes(m.swap?.used)} / ${fmtBytes(m.swap?.total)}`;
    setGauge(el("mem-gauge"), memPct, memPct > 90 ? "var(--red)" : memPct > 75 ? "var(--amber)" : "var(--green)");

    // Disk
    const diskPct = m.disk?.percent ?? 0;
    el("disk-percent").textContent = fmtPct(diskPct);
    el("disk-text").textContent = `${fmtBytes(m.disk?.used)} / ${fmtBytes(m.disk?.total)} (${m.disk?.mount || "/"})`;
    el("disk-free").textContent = `剩余 ${fmtBytes(m.disk?.free)}`;
    el("io-read").textContent = fmtBps(m.io?.read_bps);
    el("io-write").textContent = fmtBps(m.io?.write_bps);
    setGauge(el("disk-gauge"), diskPct, diskPct > 92 ? "var(--red)" : diskPct > 80 ? "var(--amber)" : "var(--blue)");

    // Network
    const up = Number(m.net?.out_bps || 0);
    const down = Number(m.net?.in_bps || 0);
    netPeak.up = Math.max(netPeak.up, up);
    netPeak.down = Math.max(netPeak.down, down);
    el("net-up").textContent = fmtBps(up);
    el("net-down").textContent = fmtBps(down);
    el("net-text").textContent = `↑ ${fmtBps(up)} · ↓ ${fmtBps(down)}`;
    el("net-up-bar").style.width = barPct(up, netPeak.up);
    el("net-down-bar").style.width = barPct(down, netPeak.down);
  } catch (e) {
    el("subtitle").textContent = "离线 / 连接失败";
  }
}

el("btn-refresh-top").addEventListener("click", refreshTop);

tick();
refreshTop();
setInterval(tick, 2000);
setInterval(refreshTop, 8000);

