# Frontend Real User Monitoring (RUM) Spoke Template

Lightweight, zero-dependency browser telemetry for static websites, documentation portals, and edge web applications (GitHub Pages, Cloudflare Pages).

## What it captures

1. **Core Web Vitals:** Largest Contentful Paint (LCP) and Cumulative Layout Shift (CLS).
2. **Unhandled errors:** `window.onerror` exceptions and unhandled promise rejections.
3. **Structured logs:** Shipped as standard OTLP/HTTP JSON (`/v1/logs`) to the central collector.

## Integration

### 1. Set configuration variables

Add your endpoint and project details before loading the snippet:

```html
<script>
  window.__OTEL_ENDPOINT__ = "https://otel.example.org";
  window.__OTEL_PROJECT__ = "cml-gallery";
  window.__OTEL_SERVICE__ = "cml-gallery";
  window.__OTEL_ENV__ = "prod";
  window.__OTEL_TOKEN__ = ""; // Leave blank when using an edge proxy or unauthenticated endpoint
</script>
```

### 2. Include the script

Paste the contents of [`rum.html`](rum.html) into your layout `<head>` or before `</body>`.

## Ingestion and Security

- **CORS origins:** The collector HTTP receiver permits cross-origin requests from `https://cmlplatform.github.io` and Leiden University domains (`https://*.leidenuniv.nl`).
- **Credential safety:** Do not embed collector bearer secrets in public client HTML. For public apps, either omit `window.__OTEL_TOKEN__` and let an edge proxy (such as Cloudflare Workers or Nginx) inject `Authorization: Bearer ...`, or provision a scoped low-privilege token.
- **Log queries:** Logs are indexed in Loki by `service_name`, `project`, and `env`, viewable on the Grafana **Logs** dashboard.
