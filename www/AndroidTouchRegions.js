// Shared Android/iOS DOM tracking; keep the original Cordova module name.
// Native code owns gesture routing; the WebView owns clicks.
var selector = [
  '.osui-bottom-sheet--is-open', '.osui-bottom-sheet-overlay',
  '.popup-dialog', '.popup-backdrop', '.osui-modal--is-open', '.osui-modal-overlay',
  '.osui-sidebar--is-open', '.osui-sidebar-overlay',
  '.feedback-message',
  '[role="dialog"]', '[role="menu"]', '[role="listbox"]',
  '.map-control-btn', '.map-touchable', '.map-touch-region', '[data-map-touch-region]',
  '[data-button]', 'button', 'a', 'input', 'select', 'textarea',
  '[contenteditable="true"]', '[role="button"]', '[role="link"]', '[role="tab"]',
  '[role="checkbox"]', '[role="radio"]', '[role="switch"]', '[role="slider"]',
  '[role="menuitem"]', '[role="option"]',
  '.tags-container [style*="cursor: pointer"]', '.tags-container [style*="cursor:pointer"]'
].join(',');

// Native setTouchableRects accepts at most this many regions on Android and iOS.
var MAX_RECTS = 256;
// Marks the transparent element the native map shows through. When present,
// every element drawn over the map is tracked, not only known control types.
var MAP_ELEMENT = '[data-mapbox-map]';
var CLIPS = /^(hidden|clip|scroll|auto)$/;
var SCROLLS = /^(auto|scroll)$/;
var REPLACED = /^(img|svg|video|canvas|iframe|object|embed|picture|input|textarea|select)$/i;

function contains(outer, inner) {
  return inner.x >= outer.x && inner.y >= outer.y &&
    inner.x + inner.width <= outer.x + outer.width &&
    inner.y + inner.height <= outer.y + outer.height;
}

function union(a, b) {
  var x = Math.min(a.x, b.x);
  var y = Math.min(a.y, b.y);
  return {
    x: x, y: y,
    width: Math.max(a.x + a.width, b.x + b.width) - x,
    height: Math.max(a.y + a.height, b.y + b.height) - y
  };
}

function area(rect) { return rect.width * rect.height; }

// Adds rect unless an existing region already covers it; drops regions it covers.
function addRect(rects, rect) {
  if (rects.some(function (existing) { return contains(existing, rect); })) return false;
  for (var i = rects.length - 1; i >= 0; i--) if (contains(rect, rects[i])) rects.splice(i, 1);
  rects.push(rect);
  return true;
}

// Merges neighbouring regions (cheapest added area first) until at most
// `limit` remain. Merging only grows WebView-owned area, so no control is
// ever dropped; at worst a little map area next to merged controls is lost.
function mergeToLimit(rects, limit) {
  while (rects.length > limit) {
    rects.sort(function (a, b) { return a.y - b.y || a.x - b.x; });
    var pairs = [];
    for (var i = 0; i + 1 < rects.length; i++) {
      pairs.push({ index: i, cost: area(union(rects[i], rects[i + 1])) - area(rects[i]) - area(rects[i + 1]) });
    }
    pairs.sort(function (a, b) { return a.cost - b.cost; });
    var excess = rects.length - limit;
    var partner = {};
    for (var p = 0; p < pairs.length && excess > 0; p++) {
      var at = pairs[p].index;
      if (partner[at] !== undefined || partner[at + 1] !== undefined) continue;
      partner[at] = at + 1; partner[at + 1] = at;
      excess--;
    }
    var merged = [];
    rects.forEach(function (rect, index) {
      var other = partner[index];
      if (other === undefined) addRect(merged, rect);
      else if (other > index) addRect(merged, union(rect, rects[other]));
    });
    rects = merged;
  }
  return rects;
}

function alpha(color) {
  if (!color || color === 'transparent') return 0;
  var match = /rgba?\(([^)]*)\)/.exec(color);
  if (!match) return 1;
  var parts = match[1].split(/[\s,\/]+/).filter(Boolean);
  if (parts.length < 4) return 1;
  var value = parseFloat(parts[3]);
  return /%$/.test(parts[3]) ? value / 100 : value;
}

function scrollable(element, style) {
  return (SCROLLS.test(style.overflowX) && element.scrollWidth > element.clientWidth) ||
    (SCROLLS.test(style.overflowY) && element.scrollHeight > element.clientHeight);
}

// True when an element draws or handles something over the map. Wrappers that
// draw nothing (transparent background, no text of their own) let touches
// through. A border or shadow alone does not claim the area inside it, so a
// framed map container stays usable.
function ownsTouches(element, style) {
  if ((element.matches && element.matches(selector)) || style.cursor === 'pointer') return true;
  if (REPLACED.test(element.tagName || '')) return true;
  if (scrollable(element, style)) return true;
  if (alpha(style.backgroundColor) > 0 ||
      (style.backgroundImage && style.backgroundImage !== 'none')) return true;
  for (var node = element.firstChild; node; node = node.nextSibling) {
    if (node.nodeType === 3 && /\S/.test(node.nodeValue)) return true;
  }
  return false;
}

module.exports = function start(win, send, options) {
  var doc = win.document;
  // Older OutSystems initialization disables broad discovery while still using
  // map-control-btn overlays. Protect only those controls in compatibility mode.
  var controlsOnly = !!(options && options.controlsOnly);
  var activeSelector = controlsOnly ? '.map-control-btn' : selector;
  var stopped = false;
  var frame = null;
  var retry = null;
  var pending = false;
  var dirty = false;
  var lastRects = null;
  var warned = false;
  var observed = [];
  var resizeObserver = win.ResizeObserver ? new win.ResizeObserver(schedule) : null;

  function observe(elements) {
    if (resizeObserver && (elements.length !== observed.length ||
        elements.some(function (element, index) { return element !== observed[index]; }))) {
      resizeObserver.disconnect();
      if (doc.documentElement) resizeObserver.observe(doc.documentElement);
      elements.forEach(function (element) { resizeObserver.observe(element); });
    }
    observed = elements;
  }

  // Visible part of an element in native pixels, clipped to the viewport and
  // to scrolling/overflow ancestors; null when hidden or fully clipped.
  function nativeRect(element, style, dpr) {
    if (style.pointerEvents === 'none' || style.visibility === 'hidden' ||
        style.visibility === 'collapse') return null;
    var bounds = element.getBoundingClientRect();
    var left = Math.max(0, bounds.left);
    var top = Math.max(0, bounds.top);
    var right = Math.min(win.innerWidth, bounds.right);
    var bottom = Math.min(win.innerHeight, bounds.bottom);
    for (var ancestor = element; ancestor; ancestor = ancestor.parentElement) {
      var css = ancestor === element ? style : win.getComputedStyle(ancestor);
      if (css.display === 'none' || css.opacity === '0' || ancestor.hidden) return null;
      if (ancestor !== element) {
        var clip = ancestor.getBoundingClientRect();
        if (CLIPS.test(css.overflowX)) { left = Math.max(left, clip.left); right = Math.min(right, clip.right); }
        if (CLIPS.test(css.overflowY)) { top = Math.max(top, clip.top); bottom = Math.min(bottom, clip.bottom); }
      }
    }
    if (right <= left || bottom <= top) return null;
    var x = Math.floor(left * dpr);
    var y = Math.floor(top * dpr);
    return { x: x, y: y, width: Math.ceil(right * dpr) - x, height: Math.ceil(bottom * dpr) - y };
  }

  // Known control types only (no map element marked, or compatibility mode).
  function collectSelected(dpr) {
    var elements = Array.prototype.slice.call(doc.querySelectorAll(activeSelector));
    observe(elements);
    var rects = [];
    elements.forEach(function (element) {
      var rect = nativeRect(element, win.getComputedStyle(element), dpr);
      if (rect) addRect(rects, rect);
    });
    return rects;
  }

  // Everything drawn over the map. Elements are visited once in document
  // order, so a registered parent (sheet, card, chip) covers its children,
  // which are then skipped by a rectangle test before any style lookup.
  function collectDrawn(mapElement, dpr) {
    var all = doc.getElementsByTagName('*');
    var rects = [];
    var owners = [];
    for (var i = 0; i < all.length; i++) {
      var element = all[i];
      // The map element and the layout containers around it are the map itself.
      if (element === mapElement || element.contains(mapElement)) continue;
      var bounds = element.getBoundingClientRect();
      var left = Math.max(0, bounds.left);
      var top = Math.max(0, bounds.top);
      var right = Math.min(win.innerWidth, bounds.right);
      var bottom = Math.min(win.innerHeight, bounds.bottom);
      if (right <= left || bottom <= top) continue; // off screen or display: none
      var x = Math.floor(left * dpr);
      var y = Math.floor(top * dpr);
      var quick = { x: x, y: y, width: Math.ceil(right * dpr) - x, height: Math.ceil(bottom * dpr) - y };
      if (rects.some(function (existing) { return contains(existing, quick); })) continue;
      var style = win.getComputedStyle(element);
      if (!ownsTouches(element, style)) continue;
      var rect = nativeRect(element, style, dpr);
      if (rect && addRect(rects, rect)) owners.push(element);
    }
    observe([mapElement].concat(owners));
    return rects;
  }

  function collect() {
    var dpr = win.devicePixelRatio || 1;
    var mapElement = !controlsOnly && doc.querySelector ? doc.querySelector(MAP_ELEMENT) : null;
    var rects = mapElement ? collectDrawn(mapElement, dpr) : collectSelected(dpr);
    if (rects.length > MAX_RECTS) {
      if (!warned) win.console.warn('Mapbox: ' + rects.length + ' overlay regions; merging nearby regions to ' +
        MAX_RECTS + '. Group controls with map-touch-region for exact map edges.');
      warned = true;
      return mergeToLimit(rects, MAX_RECTS);
    }
    warned = false;
    return rects;
  }

  function update() {
    if (stopped) return Promise.resolve();
    if (pending) { dirty = true; return Promise.resolve(); }
    var rects = collect();
    var json = JSON.stringify(rects);
    if (json === lastRects) return Promise.resolve();
    pending = true;
    return Promise.resolve().then(function () {
      if (!stopped) return send(rects);
    }).then(function () {
      lastRects = json;
    }, function (error) {
      if (!stopped) {
        win.console.warn('Mapbox: could not update overlay touch regions.', error);
        if (retry === null) retry = win.setTimeout(function () { retry = null; schedule(); }, 1000);
      }
    }).then(function () {
      pending = false;
      if (dirty) { dirty = false; schedule(); }
    });
  }

  function animating() {
    return doc.getAnimations && doc.getAnimations().some(function (animation) {
      var target = animation.effect && animation.effect.target;
      return animation.playState === 'running' && target && observed.some(function (element) {
        return target === element || target.contains(element);
      });
    });
  }

  function schedule() {
    if (stopped || frame !== null) return;
    frame = win.requestAnimationFrame(function () {
      frame = null;
      update();
      if (animating()) schedule();
    });
  }

  var observer = new win.MutationObserver(schedule);
  observer.observe(doc.documentElement, {
    childList: true, subtree: true, attributes: true,
    attributeFilter: ['class', 'style', 'hidden', 'aria-expanded', 'aria-hidden',
      'role', 'data-button', 'data-map-touch-region', 'data-mapbox-map', 'contenteditable']
  });
  var events = ['transitionrun', 'transitionend', 'transitioncancel', 'animationstart', 'animationend', 'animationcancel', 'load'];
  events.forEach(function (name) { doc.addEventListener(name, schedule, true); });
  win.addEventListener('resize', schedule);
  win.addEventListener('scroll', schedule, true);
  win.addEventListener('pagehide', stop);

  function stop() {
    if (stopped) return;
    stopped = true;
    observer.disconnect();
    if (resizeObserver) resizeObserver.disconnect();
    if (frame !== null) win.cancelAnimationFrame(frame);
    if (retry !== null) win.clearTimeout(retry);
    events.forEach(function (name) { doc.removeEventListener(name, schedule, true); });
    win.removeEventListener('resize', schedule);
    win.removeEventListener('scroll', schedule, true);
    win.removeEventListener('pagehide', stop);
    observed = [];
    lastRects = null;
    dirty = false;
    frame = retry = null;
  }

  return { stop: stop, ready: update() };
};

// Exposed for tests.
module.exports.mergeToLimit = mergeToLimit;
module.exports.MAX_RECTS = MAX_RECTS;
