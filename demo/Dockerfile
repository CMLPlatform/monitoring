FROM python:3.15.2-slim@sha256:65a65fc7b30b06cb6df4930fd4650697cb23f4c2698ab81fc87e4b031bc36928
WORKDIR /app
COPY pyproject.toml .
# uv is mounted for this one step only, so it never lands in the image.
RUN --mount=from=ghcr.io/astral-sh/uv:0.12.1,source=/uv,target=/bin/uv \
    uv pip install --system --no-cache -r pyproject.toml
COPY --chown=nobody:nogroup app.py .

USER nobody
CMD ["opentelemetry-instrument", "uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
