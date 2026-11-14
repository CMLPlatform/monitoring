# Frontend Real User Monitoring (RUM) Spoke Template

Lightweight, zero-dependency browser telemetry for static websites, documentation portals, and edge web applications (GitHub Pages, Cloudflare Pages).

## What it captures

1. **LCP:** The latest paint candidate, exported once at first interaction or page hide.
2. **CLS:** The largest session of unexpected shifts, with gaps under one second and a span under five seconds. Exported on the first hide, including zero, and on later hides when the page maximum increases.
3. **Unhandled errors:** `window.onerror` exceptions and unhandled promise rejections.
4. **Structured logs:** Shipped as standard OTLP/HTTP JSON (`/v1/logs`) to the central collector.

The script drains pending performance records before exporting. Showing the page
again preserves its CLS maximum. Later exports update the same page visit,
not independent observations. Unsupported layout-shift observation produces no score. It ignores LCP for pages loaded hidden and
candidates painted after the first hide. These rules follow the
[LCP](https://web.dev/articles/lcp) and [CLS](https://web.dev/articles/cls) definitions.
It does not measure visits restored from the back/forward cache, prerendered
page activation or content inside iframes.

## Integration

### 1. Set configuration variables

Add your endpoint and project details before loading the snippet:

```html
<script>
  window.__OTEL_ENDPOINT__ = "https://rum.example.org";
  window.__OTEL_PROJECT__ = "cml-gallery";
  window.__OTEL_SERVICE__ = "cml-gallery";
  window.__OTEL_ENV__ = "prod";
</script>
```

### 2. Include the script

Paste the contents of [`rum.html`](rum.html) into your layout `<head>` or before `</body>`.

## Ingestion and Security

Error records contain only the event type and, when available, script origin/path,
line and column. Messages, stacks and rejection values are excluded. Script URLs
exclude credentials, queries and fragments; review paths for private values before
enabling collection.
Requests omit browser credentials and the Referer header.

- **CORS origins:** The collector HTTP receiver permits cross-origin requests from `https://cmlplatform.github.io` and Leiden University domains (`https://*.leidenuniv.nl`).
- **Credential safety:** Never embed the collector bearer in public HTML. The collector supports one shared bearer, without per-project scopes. An administrator must provide a restricted proxy that injects that bearer, fixes the project identity, and limits payload size and request rate. Leave RUM disabled until the proxy and collection agreement are ready. CORS alone does not provide this boundary.
- **Log queries:** Logs are indexed in Loki by `service_name`, `project`, and `env`, viewable on the Grafana **Logs** dashboard.
