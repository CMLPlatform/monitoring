# Minimal FastAPI service for the demo overlay. All telemetry (traces,
# metrics, logs with trace context) comes from OTel auto-instrumentation —
# see compose.demo.yml. No OTel code needed here.
import logging
import random
import time

from fastapi import FastAPI, HTTPException

log = logging.getLogger("demo-api")
app = FastAPI()


@app.get("/")
def root():
    return {"ok": True}


@app.get("/work")
def work():
    time.sleep(random.uniform(0.02, 0.3))
    if random.random() < 0.1:  # NOTE: fixed 10% error rate, enough to light up RED panels
        log.error("work failed: upstream flaked")
        raise HTTPException(status_code=500, detail="upstream flaked")
    log.info("work done")
    return {"ok": True}
