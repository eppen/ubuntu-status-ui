from __future__ import annotations

from fastapi import FastAPI
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from metrics import MetricsCollector

app = FastAPI(title="Ubuntu Status UI")
collector = MetricsCollector()

app.mount("/static", StaticFiles(directory="static"), name="static")


@app.get("/")
def index():
    return FileResponse("static/index.html")


@app.get("/api/metrics")
def api_metrics():
    return collector.snapshot()


@app.get("/api/top")
def api_top(limit: int = 10):
    limit = max(1, min(50, limit))
    return {"items": collector.top_processes(limit=limit)}
