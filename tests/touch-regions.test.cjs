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
    addEventListener(name, callback) { listeners.set(name, callback); },
    removeEventListener(name, callback) { if (listeners.get(name) === callback) listeners.delete(name); },
    emit(name) { if (listeners.has(name)) listeners.get(name)(); }
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
    querySelectorAll(selector) { doc.selector = selector; return doc.elements; },
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
      calls.push({ action, args });
      if (action === 'initialize' && !initializeNow) finishInitialize = ok;
      else ok({ status: 'ok' });
    };
  } };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../www/MapboxPlugin.js'), 'utf8'), context);
  return { api: context.module.exports, calls, finish() { finishInitialize({}); } };
}

test('Android automatically starts, stops legacy script, supports manual ownership and reinitialize', async () => {
  const h = host([element(1, 1, 2, 2)]); let legacyStops = 0;
  h.win.__mapboxTouchBridge = { stop() { legacyStops++; } };
  const { api, calls } = bridge(h);
  await api.initialize({ behindWebView: true });
  assert.equal(legacyStops, 1);
  assert.deepEqual(calls.map(c => c.action), ['initialize', 'setTouchableRects']);
  await api.setTouchableRects([{ x: 0, y: 0, width: 5, height: 5 }]);
  assert.equal(h.win.listeners.size, 0);
  h.win.emit('resize'); await h.frame(); assert.equal(calls.length, 3);
  await api.initialize({ behindWebView: true });
  assert.ok(h.win.listeners.size > 0);
  await api.close(); assert.equal(h.win.listeners.size, 0);
});

test('iOS, foreground maps and explicit opt-out retain existing bridge behavior', async () => {
  for (const [platform, options] of [['ios', { behindWebView: true }], ['android', {}],
    ['android', { behindWebView: true, autoTouchRouting: false }]]) {
    const h = host(); h.win.cordova.platformId = platform;
    const { api, calls } = bridge(h);
    await api.initialize(options);
    assert.deepEqual(calls.map(c => c.action), ['initialize']);
    assert.equal(h.observers.length, 0);
  }
});

test('a late initialization callback cannot start observers after close', async () => {
  const h = host(); const b = bridge(h, false);
  const initializing = b.api.initialize({ behindWebView: true });
  await b.api.close(); b.finish(); await initializing;
  assert.equal(h.observers.length, 0);
  assert.deepEqual(b.calls.map(c => c.action), ['initialize', 'close']);
});
