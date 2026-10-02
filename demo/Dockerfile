FROM python:3.14.7-slim@sha256:51dafde81dbdb6ebde285137a295cf18a47ca95234fe388a343719cb97305b3d
WORKDIR /app
COPY pyproject.toml .
# uv is mounted for this one step only, so it never lands in the image.
RUN --mount=from=ghcr.io/astral-sh/uv:0.12.1,source=/uv,target=/bin/uv \
    uv pip install --system --no-cache -r pyproject.toml
COPY --chown=nobody:nogroup app.py .

USER nobody
CMD ["opentelemetry-instrument", "uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
