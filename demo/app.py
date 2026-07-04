"""Minimal FastAPI service for the demo overlay.

All telemetry (traces, metrics, logs with trace context) comes from OTel
auto-instrumentation — see compose.demo.yml. No OTel code needed here.
"""

import logging
import random
import time

from fastapi import FastAPI, HTTPException

ERROR_RATE = 0.1  # fixed error rate, enough to light up RED panels

logging.basicConfig(level=logging.INFO)  # root logger defaults to WARNING; we want the INFO lines too
log = logging.getLogger("demo-api")
app = FastAPI()


@app.get("/")
def root() -> dict[str, bool]:
    """Fast, always-successful endpoint."""
    return {"ok": True}


@app.get("/work")
def work() -> dict[str, bool]:
    """Simulate variable-latency work that sometimes fails."""
    time.sleep(random.uniform(0.02, 0.3))  # noqa: S311 — not crypto, just jitter
    if random.random() < ERROR_RATE:  # noqa: S311
        log.error("work failed: upstream flaked")
        raise HTTPException(status_code=500, detail="upstream flaked")
    log.info("work done")
    return {"ok": True}
