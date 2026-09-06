"""Minimal FastAPI service for the demo overlay.

All telemetry comes from OTel auto-instrumentation; see compose.demo.yml.
"""

import logging
import random
import time

from fastapi import FastAPI, HTTPException

ERROR_RATE = 0.1

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("demo-api")
app = FastAPI()


@app.get("/")
def root() -> dict[str, bool]:
    """Fast, always-successful endpoint."""
    return {"ok": True}


@app.get("/work")
def work() -> dict[str, bool]:
    """Simulate variable-latency work that sometimes fails."""
    time.sleep(random.uniform(0.02, 0.3))  # noqa: S311
    if random.random() < ERROR_RATE:  # noqa: S311
        log.error("work failed: upstream flaked")
        raise HTTPException(status_code=500, detail="upstream flaked")
    log.info("work done")
    return {"ok": True}
