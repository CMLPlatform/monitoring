FROM python:3.15.0-slim@sha256:f5b92f2a669a4c347044f29367f31983280b648250ca94dea66f98c53bc87e58
WORKDIR /app
COPY pyproject.toml .
# uv is mounted for this one step only, so it never lands in the image.
RUN --mount=from=ghcr.io/astral-sh/uv:0.12.1,source=/uv,target=/bin/uv \
    uv pip install --system --no-cache -r pyproject.toml
COPY --chown=nobody:nogroup app.py .

USER nobody
CMD ["opentelemetry-instrument", "uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
