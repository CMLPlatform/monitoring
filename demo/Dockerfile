FROM python:3.13-slim

RUN pip install --no-cache-dir \
    fastapi==0.139.0 \
    uvicorn==0.49.0 \
    opentelemetry-distro==0.64b0 \
    opentelemetry-exporter-otlp==1.43.0 \
    opentelemetry-instrumentation-fastapi==0.64b0

WORKDIR /app
COPY app.py .

CMD ["opentelemetry-instrument", "uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
