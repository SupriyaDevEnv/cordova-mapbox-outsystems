const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const start = require('../www/AndroidTouchRegions');

function target() {
  const listeners = new Map();
  return {
    listeners,
    addEventListener(name, callback) {
      if (!listeners.has(name)) listeners.set(name, new Set());
      listeners.get(name).add(callback);
    },
    removeEventListener(name, callback) {
      const set = listeners.get(name);
      if (set) { set.delete(callback); if (!set.size) listeners.delete(name); }
    },
    emit(name) { for (const cb of listeners.get(name) || []) cb(); }
  };
}
function element(left, top, width, height, style = {}, parentElement = null) {
  return {
    bounds: { left, top, right: left + width, bottom: top + height },
    style, parentElement,
    getBoundingClientRect() { return this.bounds; },
    contains(child) { while (child) { if (child === this) return true; child = child.parentElement; } return false; }
  };
}
function host(elements = []) {
  const frames = new Map(), timers = new Map(), observers = [], warnings = [];
  let id = 0;
  const doc = Object.assign(target(), {
    documentElement: element(0, 0, 1000, 800),
    elements, animations: [],
    querySelectorAll(selector) {
      doc.selector = selector;
      return selector === '.map-control-btn' ? doc.elements.filter(node => node.mapControl) : doc.elements;
    },
    getAnimations() { return doc.animations; }
  });
  class Observer {
    constructor(callback) { this.callback = callback; this.nodes = []; observers.push(this); }
    observe(node) { this.nodes.push(node); }
    disconnect() { this.nodes = []; }
  }
  const win = Object.assign(target(), {
    document: doc, devicePixelRatio: 2, innerWidth: 1000, innerHeight: 800,
    cordova: { platformId: 'android' },
    getComputedStyle(node) { return Object.assign({ display: 'block', opacity: '1', visibility: 'visible', pointerEvents: 'auto' }, node.style); },
    MutationObserver: Observer, ResizeObserver: Observer,
    requestAnimationFrame(callback) { frames.set(++id, callback); return id; },
    cancelAnimationFrame(id) { frames.delete(id); },
    setTimeout(callback) { timers.set(++id, callback); return id; },
    clearTimeout(id) { timers.delete(id); },
    console: { warn(...args) { warnings.push(args); } }
  });
  return { win, doc, frames, timers, observers, warnings,
    async frame() {
      const callbacks = [...frames.values()]; frames.clear();
      callbacks.forEach(callback => callback());
      await new Promise(resolve => setImmediate(resolve));
    }
  };
}

test('clips and converts rectangles, removes contained regions in either DOM order, includes tag selectors', async () => {
  const h = host([element(20, 20, 5, 5), element(-5, 10, 55, 30), element(30, 20, 5, 5)]);
  const sent = [];
  const controller = start(h.win, rects => sent.push(rects));
  await controller.ready;
  assert.deepEqual(sent, [[{ x: 0, y: 20, width: 100, height: 60 }]]);
  assert.match(h.doc.selector, /tags-container/);
  assert.match(h.doc.selector, /data-map-touch-region/);
  h.win.emit('scroll'); h.win.emit('resize');
  assert.equal(h.frames.size, 1);
  await h.frame(); assert.equal(sent.length, 1);
  controller.stop();
});

test('ignores hidden ancestors and pointer-events:none; clips to scrolling ancestors', async () => {
  const invisible = element(0, 0, 100, 100, { opacity: '0' });
  const scroller = element(10, 10, 40, 40, { overflowX: 'auto', overflowY: 'hidden' });
  const h = host([element(1, 1, 5, 5, {}, invisible), element(2, 2, 5, 5, { pointerEvents: 'none' }),
    element(0, 0, 100, 100, {}, scroller), element(1001, 1, 5, 5)]);
  const sent = [];
  const controller = start(h.win, rects => sent.push(rects));
  await controller.ready;
  assert.deepEqual(sent[0], [{ x: 20, y: 20, width: 80, height: 80 }]);
  h.doc.elements = []; h.win.emit('scroll'); await h.frame();
  assert.deepEqual(sent[1], [], 'removing overlays must clear native exclusions');
  controller.stop();
});

test('over 50 independent regions preserves WebView controls instead of dropping them', async () => {
  const h = host(Array.from({ length: 51 }, (_, index) => element(index * 10, 0, 2, 2)));
  const sent = [];
  const controller = start(h.win, rects => sent.push(rects));
  await controller.ready;
  assert.deepEqual(sent[0], [{ x: 0, y: 0, width: 2000, height: 1600 }]);
  assert.equal(h.warnings.length, 1);
  h.doc.elements = [element(1, 1, 2, 2)]; h.win.emit('resize'); await h.frame();
  assert.deepEqual(sent[1], [{ x: 2, y: 2, width: 4, height: 4 }]);
  controller.stop();
});

test('updates during relevant animations, observes replacement elements, and cleans up', async () => {
  const node = element(5, 5, 10, 10);
  const h = host([node]); const sent = [];
  const controller = start(h.win, rects => sent.push(rects));
  await controller.ready;
  h.doc.animations = [{ playState: 'running', effect: { target: node } }];
  h.doc.emit('transitionrun'); await h.frame();
  assert.equal(h.frames.size, 1);
  node.bounds.left = 10; node.bounds.right = 20;
  await h.frame(); assert.equal(sent[1][0].x, 20);
  h.doc.animations = []; await h.frame(); assert.equal(h.frames.size, 0);
  const replacement = element(30, 30, 20, 20);
  h.doc.elements = [replacement];
  h.observers.find(observer => observer.nodes.includes(h.doc.documentElement) && observer.nodes.length === 1).callback();
  await h.frame();
  assert.ok(h.observers.some(observer => observer.nodes.includes(replacement)));
  h.win.emit('resize'); controller.stop();
  assert.equal(h.frames.size, 0); assert.equal(h.timers.size, 0);
  assert.equal(h.win.listeners.size, 0); assert.equal(h.doc.listeners.size, 0);
  assert.ok(h.observers.every(observer => observer.nodes.length === 0));
  assert.ok(!h.doc.listeners.has('touchend'), 'never synthesize clicks');
});

test('failed bridge update retries the same rectangles and close cancels retry', async () => {
  const h = host([element(1, 1, 2, 2)]); let calls = 0;
  const controller = start(h.win, () => { calls++; if (calls === 1) return Promise.reject(new Error('transient')); });
  await controller.ready;
  assert.equal(h.timers.size, 1);
  const callback = [...h.timers.values()][0]; h.timers.clear(); callback(); await h.frame();
  assert.equal(calls, 2);
  controller.stop();
});

test('serializes bridge writes and sends latest DOM after an outstanding update', async () => {
  const h = host([element(1, 1, 2, 2)]); const sent = []; let release;
  const controller = start(h.win, rects => {
    sent.push(rects);
    if (sent.length === 1) return new Promise(resolve => { release = resolve; });
  });
  await Promise.resolve();
  h.doc.elements = [element(30, 30, 5, 5)]; h.win.emit('resize'); await h.frame();
  assert.equal(sent.length, 1);
  release(); await controller.ready; await h.frame();
  assert.equal(sent.length, 2); assert.equal(sent[1][0].x, 60);
  controller.stop();
});

function bridge(h, initializeNow = true) {
  const calls = []; let finishInitialize;
  const context = { window: h.win, module: { exports: {} }, require(name) {
    if (name === './AndroidTouchRegions') return start;
    assert.equal(name, 'cordova/exec');
    return (ok, fail, service, action, args) => {
      calls.push({ action, args, ok, fail });
      if (action === 'registerCloseCallback') return;
      if (action === 'initialize' && !initializeNow) finishInitialize = ok;
      else ok({ status: 'ok' });
    };
  } };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../www/MapboxPlugin.js'), 'utf8'), context);
  return { api: context.module.exports, calls, finish() { finishInitialize({}); } };
}

for (const platform of ['android', 'ios']) {
test(platform + ' automatically starts, stops legacy script, supports manual ownership and reinitialize', async () => {
  const h = host([element(1, 1, 2, 2)]); let legacyStops = 0;
  h.win.cordova.platformId = platform;
  h.win.__mapboxTouchBridge = { stop() { legacyStops++; } };
  const { api, calls } = bridge(h);
  await api.initialize({ behindWebView: true });
  assert.equal(legacyStops, 1);
  assert.deepEqual(calls.map(c => c.action), ['initialize', 'registerCloseCallback', 'setTouchableRects']);
  await api.setTouchableRects([{ x: 0, y: 0, width: 5, height: 5 }]);
  assert.equal(h.win.listeners.size, 0);
  h.win.emit('resize'); await h.frame(); assert.equal(calls.length, 4);
  await api.initialize({ behindWebView: true });
  assert.ok(h.win.listeners.size > 0);
  await api.close(); assert.equal(h.win.listeners.size, 0);
});
}

test('unsupported platforms and foreground maps retain existing bridge behavior', async () => {
  for (const [platform, options] of [['browser', { behindWebView: true }], ['android', {}], ['ios', {}]]) {
    const h = host(); h.win.cordova.platformId = platform;
    const { api, calls } = bridge(h);
    await api.initialize(options);
    assert.deepEqual(calls.map(c => c.action), platform === 'browser' ? ['initialize'] : ['initialize', 'registerCloseCallback']);
    assert.equal(h.observers.length, 0);
  }
});

test('iOS uses native pixels and its 20-region budget, then clears dismissed overlays', async () => {
  const h = host(Array.from({ length: 20 }, (_, i) => element(i * 10, 10, 2, 2)));
  h.win.cordova.platformId = 'ios';
  h.win.devicePixelRatio = 3;
  const b = bridge(h);
  await b.api.initialize({ behindWebView: true });
  let rects = b.calls.at(-1).args[0];
  assert.equal(rects.length, 20);
  assert.deepEqual(rects[1], { x: 30, y: 30, width: 6, height: 6 });
  h.doc.elements.push(element(300, 10, 2, 2));
  h.win.emit('resize'); await h.frame();
  assert.deepEqual(b.calls.at(-1).args[0], [{ x: 0, y: 0, width: 3000, height: 2400 }]);
  h.doc.elements = [];
  h.win.emit('resize'); await h.frame();
  assert.deepEqual(b.calls.at(-1).args[0], []);
  await b.api.close();
});

test('a late initialization callback cannot start observers after close', async () => {
  const h = host(); const b = bridge(h, false);
  const initializing = b.api.initialize({ behindWebView: true });
  const rejected = assert.rejects(initializing, /cancelled/);
  await b.api.close(); b.finish(); await rejected;
  assert.equal(h.observers.length, 0);
  assert.deepEqual(b.calls.map(c => c.action), ['initialize', 'close']);
});

test('close removes only owned listeners and does not restart after a late observer callback', async () => {
  const h = host(); let external = 0;
  h.win.addEventListener('scroll', () => external++);
  h.doc.addEventListener('load', () => external++);
  const controller = start(h.win, () => Promise.resolve());
  await controller.ready;
  h.win.emit('resize');
  controller.stop(); controller.stop();
  h.observers.forEach(observer => observer.callback());
  h.win.emit('scroll'); h.doc.emit('load');
  assert.equal(external, 2);
  assert.equal(h.win.listeners.size, 1);
  assert.equal(h.doc.listeners.size, 1);
  assert.equal(h.frames.size, 0);
  assert.equal(h.timers.size, 0);
  assert.ok(h.observers.every(observer => observer.nodes.length === 0));
});

test('native close stops automatic observers and manual-mode event callbacks', async () => {
  const h = host(); const b = bridge(h); let events = 0;
  await b.api.initialize({ behindWebView: true });
  b.api.onCompassChanged(() => events++);
  const compass = b.calls.find(c => c.action === 'registerCompassCallback');
  await b.api.setTouchableRects([]);
  const closed = b.calls.find(c => c.action === 'registerCloseCallback');
  closed.ok({ closed: true });
  const before = events;
  compass.ok({ bearing: 10 });
  assert.equal(events, before);
  assert.equal(h.win.listeners.size, 0);
  await b.api.initialize({ behindWebView: true });
  closed.ok({ closed: true });
  assert.ok(h.win.listeners.size > 0, 'old native close must not close the reopened session');
  b.calls.filter(c => c.action === 'registerCloseCallback').at(-1).ok({ closed: true });
  assert.equal(h.win.listeners.size, 0);
});

test('repeated close succeeds and old subscriptions cannot deliver into a reopened map', async () => {
  const h = host(); const b = bridge(h); let events = 0;
  await b.api.initialize({ behindWebView: true });
  b.api.onMarkerClick(() => events++);
  const old = b.calls.find(c => c.action === 'registerMarkerClickCallback');
  await Promise.all([b.api.close(), b.api.close()]);
  await b.api.initialize({ behindWebView: true });
  const before = events; old.ok({ id: 'stale' });
  assert.equal(events, before);
  await b.api.close();
});

for (const platform of ['android', 'ios']) {
  test(platform + ' preserves legacy initialization and protects only map-control-btn regions', async () => {
    const button = Object.assign(element(20, 30, 40, 40), { mapControl: true });
    const h = host([element(0, 0, 1000, 800), button]);
    h.win.cordova.platformId = platform;
    const b = bridge(h);
    const options = { behindWebView: true, inline: true, autoTouchRouting: false, x: 0, y: 158 };
    const original = { ...options };
    await b.api.initialize(options);
    assert.deepEqual(options, original);
    assert.deepEqual(b.calls[0].args[0], original);
    assert.equal(h.doc.selector, '.map-control-btn');
    assert.deepEqual(b.calls.at(-1).args[0], [{ x: 40, y: 60, width: 80, height: 80 }]);
    // The fullscreen layout must not steal gestures in the open map area.
    assert.equal(b.calls.at(-1).args[0].some(r => 400 >= r.x && 400 < r.x + r.width), false);

    h.doc.elements = [];
    h.observers.forEach(o => o.callback()); await h.frame();
    assert.deepEqual(b.calls.at(-1).args[0], [], 'navigation removes stale exclusions');
    const replacement = Object.assign(element(100, 50, 40, 40), { mapControl: true });
    h.doc.elements = [replacement];
    h.observers.forEach(o => o.callback()); await h.frame();
    assert.deepEqual(b.calls.at(-1).args[0], [{ x: 200, y: 100, width: 80, height: 80 }]);

    await b.api.setTouchableRects([]);
    const count = b.calls.length;
    h.win.emit('resize'); h.observers.forEach(o => o.callback()); await h.frame();
    assert.equal(b.calls.length, count, 'explicit manual ownership stops compatibility discovery');
    await b.api.close();
    await b.api.initialize(options);
    assert.deepEqual(b.calls.at(-1).args[0], [{ x: 200, y: 100, width: 80, height: 80 }]);
    await b.api.close();
    assert.equal(h.win.listeners.size, 0);
    assert.equal(h.doc.listeners.size, 0);
  });
}

test('manual ownership during initialization still registers native close cleanup', async () => {
  const h = host(); const b = bridge(h, false);
  const initializing = b.api.initialize({ behindWebView: true });
  await b.api.setTouchableRects([]);
  b.finish(); await initializing;
  assert.equal(h.observers.length, 0);
  let events = 0;
  b.api.onMarkerClick(() => events++);
  const marker = b.calls.at(-1);
  const before = events;
  b.calls.find(c => c.action === 'registerCloseCallback').ok({ closed: true });
  marker.ok({ id: 'stale' });
  assert.equal(events, before);
});

test('stopping before the first bridge microtask prevents stale region writes', async () => {
  const h = host([element(10, 10, 10, 10)]); const sent = [];
  const controller = start(h.win, rects => sent.push(rects));
  controller.stop();
  await controller.ready;
  assert.deepEqual(sent, []);
  assert.equal(h.frames.size, 0);
});

test('a rejected write after navigation cannot retry or restart stopped tracking', async () => {
  const h = host([element(10, 10, 10, 10)]); let reject;
  const controller = start(h.win, () => new Promise((resolve, fail) => { reject = fail; }));
  await Promise.resolve();
  h.win.emit('resize'); await h.frame();
  controller.stop(); reject(new Error('old session closed'));
  await controller.ready;
  assert.equal(h.timers.size, 0);
  assert.equal(h.frames.size, 0);
  assert.equal(h.warnings.length, 0);
});

for (const stopMode of ['missing', 'throws', 'clears globals']) {
  test('close cleans legacy resources when stop ' + stopMode, async () => {
    const h = host(); const b = bridge(h);
    await b.api.initialize({ behindWebView: true });
    let externalEvents = 0;
    const independent = () => externalEvents++;
    h.win.addEventListener('scroll', independent);
    h.doc.addEventListener('load', independent);
    const schedule = () => { throw new Error('legacy listener survived'); };
    const pagehide = schedule;
    h.win.addEventListener('resize', schedule);
    h.win.addEventListener('scroll', schedule, true);
    h.win.addEventListener('pagehide', pagehide);
    for (const event of ['transitionrun', 'transitionend', 'transitioncancel',
      'animationstart', 'animationend', 'animationcancel', 'load']) {
      h.doc.addEventListener(event, schedule, true);
    }
    h.win.__mapboxTouchHandlers = { schedule, pagehide };
    const observer = h.win.__mapboxTouchObserver = new h.win.MutationObserver(schedule);
    const resize = h.win.__mapboxResizeObserver = new h.win.ResizeObserver(schedule);
    observer.observe(h.doc.documentElement); resize.observe(h.doc.documentElement);
    const legacy = h.win.__mapboxTouchBridge = {
      frame: h.win.requestAnimationFrame(schedule), retry: h.win.setTimeout(schedule)
    };
    if (stopMode === 'throws') legacy.stop = () => { throw new Error('legacy stop failed'); };
    if (stopMode === 'clears globals') legacy.stop = () => {
      assert.notEqual(legacy.stopped, true, 'do not bypass a legacy stop guard');
      h.win.__mapboxTouchObserver = h.win.__mapboxTouchHandlers = null;
      legacy.frame = legacy.retry = null;
    };
    await b.api.close(); await b.api.close();
    assert.equal(b.calls.at(-1).action, 'close', 'native teardown must still run');
    assert.equal(legacy.stopped, true);
    assert.equal(h.frames.size, 0); assert.equal(h.timers.size, 0);
    assert.equal(observer.nodes.length, 0); assert.equal(resize.nodes.length, 0);
    h.win.emit('resize'); h.win.emit('scroll'); h.win.emit('pagehide'); h.doc.emit('load');
    assert.equal(externalEvents, 2, 'unrelated listeners remain active');
    assert.equal(h.win.__mapboxTouchBridge, null);
  });
}
