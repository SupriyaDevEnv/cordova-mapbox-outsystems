// Tracking every element drawn over a [data-mapbox-map] element.
const test = require('node:test');
const assert = require('node:assert/strict');
const start = require('../www/AndroidTouchRegions');

const DEFAULT_STYLE = {
  display: 'block', opacity: '1', visibility: 'visible', pointerEvents: 'auto',
  overflowX: 'visible', overflowY: 'visible', backgroundColor: 'rgba(0, 0, 0, 0)',
  backgroundImage: 'none', cursor: 'auto'
};
const WHITE = { backgroundColor: 'rgb(255, 255, 255)' };

function node(tag, left, top, width, height, style = {}, opts = {}) {
  return {
    tagName: tag.toUpperCase(), style, parentElement: null, children: [],
    bounds: { left, top, right: left + width, bottom: top + height },
    text: opts.text, interactive: !!opts.interactive, mapControl: !!opts.mapControl,
    map: !!opts.map, hidden: false,
    scrollWidth: opts.scrollWidth || width, clientWidth: width,
    scrollHeight: opts.scrollHeight || height, clientHeight: height,
    getBoundingClientRect() { return this.bounds; },
    contains(child) { while (child) { if (child === this) return true; child = child.parentElement; } return false; },
    matches() { return this.interactive; },
    get firstChild() { return this.text ? { nodeType: 3, nodeValue: this.text, nextSibling: null } : null; }
  };
}
function append(parent, ...children) {
  children.forEach(child => { child.parentElement = parent; parent.children.push(child); });
  return parent;
}
function inOrder(root) { return [root].concat(...root.children.map(inOrder)); }

function host(root, dpr = 1) {
  const frames = new Map(), observers = [], warnings = [];
  let id = 0;
  const listeners = () => ({ addEventListener() {}, removeEventListener() {} });
  const doc = Object.assign(listeners(), {
    documentElement: root,
    querySelector(selector) {
      assert.equal(selector, '[data-mapbox-map]');
      return inOrder(root).find(n => n.map) || null;
    },
    querySelectorAll(selector) {
      doc.selector = selector;
      return inOrder(root).filter(n => selector === '.map-control-btn' ? n.mapControl : n.interactive);
    },
    getElementsByTagName(name) { assert.equal(name, '*'); return inOrder(root); },
    getAnimations() { return []; }
  });
  class Observer {
    constructor(callback) { this.callback = callback; this.nodes = []; observers.push(this); }
    observe(n) { this.nodes.push(n); }
    disconnect() { this.nodes = []; }
  }
  const win = Object.assign(listeners(), {
    document: doc, devicePixelRatio: dpr, innerWidth: 400, innerHeight: 800,
    cordova: { platformId: 'android' },
    getComputedStyle(n) { return Object.assign({}, DEFAULT_STYLE, n.style); },
    MutationObserver: Observer, ResizeObserver: Observer,
    requestAnimationFrame(callback) { frames.set(++id, callback); return id; },
    cancelAnimationFrame(frameId) { frames.delete(frameId); },
    setTimeout() { return ++id; }, clearTimeout() {},
    console: { warn(...args) { warnings.push(args); } }
  });
  return { win, doc, observers, warnings };
}

// A map screen like the OutSystems layout: header, chips, a transparent
// control column, labels, a framed area and a bottom sheet over the map.
function mapScreen() {
  const html = node('html', 0, 0, 400, 800);
  const body = node('body', 0, 0, 400, 800);
  const header = append(node('div', 0, 0, 400, 60, WHITE), node('span', 10, 10, 40, 40, {}, { text: 'Map' }));
  const map = node('div', 0, 60, 400, 740, {}, { map: true });
  const chips = append(node('div', 0, 70, 400, 30, { overflowX: 'auto' }, { scrollWidth: 640 }),
    node('div', 10, 72, 60, 26, WHITE, { text: 'All' }), node('div', 80, 72, 80, 26, WHITE, { text: 'Finds' }));
  const layers = node('div', 350, 500, 40, 40, WHITE);
  const tools = append(node('div', 350, 550, 40, 40, { cursor: 'pointer' }), node('svg', 360, 560, 20, 20));
  const column = append(node('div', 340, 200, 60, 400), layers, tools);
  const framed = append(node('div', 20, 300, 200, 150, { borderTopWidth: '2px' }));
  const label = node('div', 20, 520, 100, 20, {}, { text: '300 m' });
  const ghost = node('div', 20, 600, 100, 40, Object.assign({ pointerEvents: 'none' }, WHITE));
  const closedMenu = append(node('div', 0, 0, 0, 0, Object.assign({ display: 'none' }, WHITE)),
    node('div', 0, 0, 0, 0, {}, { text: 'Offline Maps' }));
  const clearBackdrop = node('div', 0, 60, 400, 740, { backgroundColor: 'rgba(0, 0, 0, 0)' });
  const sheet = append(node('div', 0, 700, 400, 150, Object.assign({ overflowY: 'hidden' }, WHITE)),
    node('div', 0, 710, 400, 40, {}, { text: 'Explore' }), node('div', 0, 760, 400, 60, {}, { text: 'Trail' }));
  const content = append(node('div', 0, 60, 400, 740), map, chips, column, framed, label, ghost,
    closedMenu, clearBackdrop, sheet);
  append(html, append(body, append(node('div', 0, 0, 400, 800), header, content)));
  return { html, map, header, chips, column, layers, tools, sheet };
}

test('tracks everything drawn over the map, skips transparent wrappers and the map containers', async () => {
  const screen = mapScreen();
  const h = host(screen.html, 2);
  const sent = [];
  const controller = start(h.win, rects => sent.push(rects));
  await controller.ready;
  assert.deepEqual(sent[0], [
    { x: 0, y: 0, width: 800, height: 120 },     // header (painted)
    { x: 0, y: 140, width: 800, height: 60 },    // scrolling chips row; chips inside are covered
    { x: 700, y: 1000, width: 80, height: 80 },  // painted control in a transparent column
    { x: 700, y: 1100, width: 80, height: 80 },  // transparent clickable (cursor: pointer) control
    { x: 40, y: 1040, width: 200, height: 40 },  // text label
    { x: 0, y: 1400, width: 800, height: 200 }   // bottom sheet, clipped to the viewport
  ]);
  const resize = h.observers.find(o => o.nodes.includes(screen.map));
  assert.ok(resize, 'observes the map element for layout changes');
  assert.ok(resize.nodes.includes(screen.sheet) && !resize.nodes.includes(screen.column));
  controller.stop();
});

test('without a marked map element only known control types are tracked', async () => {
  const screen = mapScreen();
  screen.map.map = false;
  screen.layers.interactive = true;
  const h = host(screen.html);
  const sent = [];
  const controller = start(h.win, rects => sent.push(rects));
  await controller.ready;
  assert.deepEqual(sent[0], [{ x: 350, y: 500, width: 40, height: 40 }]);
  controller.stop();
});

test('compatibility mode keeps protecting only map-control-btn even with a marked map element', async () => {
  const screen = mapScreen();
  screen.tools.mapControl = true;
  const h = host(screen.html);
  const sent = [];
  const controller = start(h.win, rects => sent.push(rects), { controlsOnly: true });
  await controller.ready;
  assert.equal(h.doc.selector, '.map-control-btn');
  assert.deepEqual(sent[0], [{ x: 350, y: 550, width: 40, height: 40 }]);
  controller.stop();
});

test('mergeToLimit keeps every region covered and stays within the limit', () => {
  const rects = Array.from({ length: 600 }, (_, i) => ({ x: (i % 40) * 25, y: Math.floor(i / 40) * 25, width: 10, height: 10 }));
  const merged = start.mergeToLimit(rects.slice(), 256);
  assert.ok(merged.length <= 256);
  for (const r of rects) {
    assert.ok(merged.some(m => r.x >= m.x && r.y >= m.y && r.x + r.width <= m.x + m.width &&
      r.y + r.height <= m.y + m.height));
  }
  const total = merged.reduce((sum, m) => sum + m.width * m.height, 0);
  assert.ok(total < 1000 * 375 / 2, 'merges neighbours instead of covering the whole area');
});
