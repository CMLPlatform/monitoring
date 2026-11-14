import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { runInNewContext } from 'node:vm';

const source = readFileSync(new URL('./rum.html', import.meta.url), 'utf8').split('<script>')[1].split('</script>')[0];

function browser(initialVisibility = 'visible', unsupportedCls = false) {
  const logs = [];
  const listeners = {};
  const observers = {};
  const on = (name, handler) => (listeners[name] ??= []).push(handler);
  const document = { visibilityState: initialVisibility, addEventListener: on };
  const window = {
    __OTEL_ENDPOINT__: 'https://rum.example.org',
    location: { origin: 'https://example.org', pathname: '/' },
    addEventListener: on,
  };
  class PerformanceObserver {
    static supportedEntryTypes = unsupportedCls === 'missing' ? undefined : unsupportedCls === 'silent' ? ['mark', 'measure'] : ['largest-contentful-paint', 'layout-shift'];
    pending = [];
    disconnected = false;
    constructor(callback) { this.callback = callback; }
    observe({ type }) {
      if (unsupportedCls === 'silent' && type === 'layout-shift') return;
      if (unsupportedCls === true && type === 'layout-shift') throw new Error('unsupported');
      observers[type] = this;
    }
    takeRecords() { return this.pending.splice(0); }
    disconnect() { this.disconnected = true; }
  }
  window.PerformanceObserver = PerformanceObserver;
  runInNewContext(source, {
    window, document, PerformanceObserver, navigator: { userAgent: 'test-browser' },
    fetch: (_url, options) => {
      logs.push(JSON.parse(options.body).resourceLogs[0].scopeLogs[0].logRecords[0]);
      return Promise.resolve();
    },
  });
  const emit = (name, timeStamp = 10000) => listeners[name]?.forEach((handler) => handler({ timeStamp }));
  const deliver = (type, entries) => observers[type].callback({ getEntries: () => entries });
  const hide = (time = 10000) => { document.visibilityState = 'hidden'; emit('visibilitychange', time); };
  const values = (vital, key) => logs.filter((log) => log.body.stringValue === `WebVital: ${vital}`).map((log) => log.attributes.find((attr) => attr.key === key).value.doubleValue);
  return { logs, document, observers, emit, deliver, hide, values };
}
const shift = (value, startTime, hadRecentInput = false) => ({ value, startTime, hadRecentInput });

test('CLS reports the largest session instead of summing separate sessions', () => {
  const page = browser();
  page.deliver('layout-shift', [shift(0.12, 100), shift(0.13, 2100)]);
  page.hide();
  assert.deepEqual(page.values('CLS', 'cls_score'), [0.13]);
});

test('CLS sums shifts in the same session and excludes recent input', () => {
  const page = browser();
  page.deliver('layout-shift', [shift(0.12, 100), shift(0.13, 900), shift(0.8, 950, true)]);
  page.hide();
  assert.deepEqual(page.values('CLS', 'cls_score'), [0.25]);
});

test('CLS starts a new session at a one-second gap or five-second span', () => {
  for (const times of [[100, 1100], [0, 900, 1800, 2700, 3600, 4500, 5000]]) {
    const page = browser();
    page.deliver('layout-shift', times.map((time) => shift(0.1, time)));
    page.hide();
    assert.deepEqual(page.values('CLS', 'cls_score'), [times.length === 2 ? 0.1 : 0.6]);
  }
});

test('CLS drains queued shifts and retains the page maximum across hide/show cycles', () => {
  const page = browser();
  page.observers['layout-shift'].pending.push(shift(0.3, 100));
  page.hide(200);
  page.hide(200);
  page.document.visibilityState = 'visible';
  page.emit('visibilitychange', 300);
  page.deliver('layout-shift', [shift(0.1, 2100)]);
  page.hide(2200);
  page.document.visibilityState = 'visible';
  page.deliver('layout-shift', [shift(0.4, 4100)]);
  page.hide(4200);
  assert.deepEqual(page.values('CLS', 'cls_score'), [0.3, 0.4]);
});

test('LCP sends only the latest candidate at first interaction', () => {
  const page = browser();
  page.deliver('largest-contentful-paint', [{ startTime: 100 }]);
  page.deliver('largest-contentful-paint', [{ startTime: 2000 }]);
  assert.deepEqual(page.values('LCP', 'duration_ms'), []);
  page.emit('pointerdown', 2100);
  page.hide();
  assert.deepEqual(page.values('LCP', 'duration_ms'), [2000]);
  assert.equal(page.observers['largest-contentful-paint'].disconnected, true);
});

test('LCP drains queued candidates at hide and ignores later callbacks', () => {
  const page = browser();
  page.deliver('largest-contentful-paint', [{ startTime: 100 }]);
  page.observers['largest-contentful-paint'].pending.push({ startTime: 2000 });
  page.hide(2100);
  page.deliver('largest-contentful-paint', [{ startTime: 3000 }]);
  page.document.visibilityState = 'visible';
  page.hide(4000);
  assert.deepEqual(page.values('LCP', 'duration_ms'), [2000]);
});

test('LCP finalises on keyboard and scroll interactions', () => {
  for (const event of ['keydown', 'scroll', 'pointerdown', 'touchstart']) {
    const page = browser();
    page.deliver('largest-contentful-paint', [{ startTime: 100 }]);
    page.emit(event, 200);
    assert.deepEqual(page.values('LCP', 'duration_ms'), [100]);
  }
});

test('LCP excludes pages loaded hidden and candidates painted after first hide', () => {
  const hiddenPage = browser('hidden');
  hiddenPage.document.visibilityState = 'visible';
  hiddenPage.emit('pointerdown');
  assert.deepEqual(hiddenPage.values('LCP', 'duration_ms'), []);
  const page = browser();
  page.observers['largest-contentful-paint'].pending.push({ startTime: 3000 });
  page.hide(2000);
  assert.deepEqual(page.values('LCP', 'duration_ms'), []);
});

test('CLS reports a supported zero once and emits no score for unsupported observation', () => {
  const supported = browser();
  supported.hide();
  supported.hide();
  assert.deepEqual(supported.values('CLS', 'cls_score'), [0]);
  const unsupported = browser('visible', true);
  unsupported.hide();
  assert.deepEqual(unsupported.values('CLS', 'cls_score'), []);
});

test('CLS stays unknown when unsupported observe silently does nothing', () => {
  for (const support of ['silent', 'missing']) {
    const page = browser('visible', support);
    page.hide();
    assert.deepEqual(page.values('CLS', 'cls_score'), []);
  }
});
