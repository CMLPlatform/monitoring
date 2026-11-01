# Frontend Real User Monitoring (RUM) Spoke Template

This template provides lightweight, zero-dependency browser observability for
static websites, documentation portals, and edge-served web apps (e.g., GitHub Pages,
Cloudflare Pages).

## What it captures

1. **Core Web Vitals**: Largest Contentful Paint (LCP) and Cumulative Layout Shift (CLS).
2. **Unhandled JavaScript Errors**: `window.onerror` exceptions and unhandled promise rejections.
3. **Traceable Logs**: Shipped as standard OTLP/HTTP JSON (`/v1/logs`) directly to the central
   OpenTelemetry Collector.

## Usage in Astro / HTML

1. Define your endpoint and project configuration before the snippet:

```html
<script>
  window.__OTEL_ENDPOINT__ = "https://otel.example.org";
  window.__OTEL_PROJECT__ = "cml-gallery";
  window.__OTEL_SERVICE__ = "cml-gallery";
  window.__OTEL_ENV__ = "prod";
  window.__OTEL_TOKEN__ = "<optional-otlp-token>";
</script>
```

2. Copy the contents of [`rum.html`](rum.html) into your layout `<head>` or before `</body>`.

## Ingestion in OpenTelemetry Collector

The collector's HTTP receiver (`0.0.0.0:4318`) is preconfigured with CORS headers allowing
cross-origin POST requests from `https://*.github.io` and `https://*.leidenuniv.nl`.
Logs are indexed in Loki by `service_name`, `project`, and `env`, viewable on the
**Logs** dashboard.
