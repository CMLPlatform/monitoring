FROM python:3.14.7-slim AS builder
COPY --from=ghcr.io/astral-sh/uv:0.12.1 /uv /bin/
WORKDIR /app
COPY pyproject.toml .
RUN uv pip install --system --no-cache -r pyproject.toml

FROM python:3.14.7-slim
COPY --from=builder /usr/local/lib/python3.14/site-packages /usr/local/lib/python3.14/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin
WORKDIR /app
COPY --chown=nobody:nogroup app.py .

USER nobody
CMD ["opentelemetry-instrument", "uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
