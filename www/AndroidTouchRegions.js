// DOM rectangles only: Android owns gesture routing; the WebView owns clicks.
var selector = [
  '.osui-bottom-sheet--is-open', '.osui-bottom-sheet-overlay',
  '.popup-dialog', '.popup-backdrop', '.osui-modal--is-open', '.osui-modal-overlay',
  '.osui-sidebar--is-open', '.osui-sidebar-overlay',
  '[role="dialog"]', '[role="menu"]', '[role="listbox"]',
  '.map-touchable', '.map-touch-region', '[data-map-touch-region]',
  '[data-button]', 'button', 'a', 'input', 'select', 'textarea',
  '[contenteditable="true"]', '[role="button"]', '[role="link"]', '[role="tab"]',
  '[role="checkbox"]', '[role="radio"]', '[role="switch"]', '[role="slider"]',
  '[role="menuitem"]', '[role="option"]',
  '.tags-container [style*="cursor: pointer"]', '.tags-container [style*="cursor:pointer"]'
].join(',');

function contains(outer, inner) {
  return inner.x >= outer.x && inner.y >= outer.y &&
    inner.x + inner.width <= outer.x + outer.width &&
    inner.y + inner.height <= outer.y + outer.height;
}

module.exports = function start(win, send) {
  var doc = win.document;
  var stopped = false;
  var frame = null;
  var retry = null;
  var pending = false;
  var dirty = false;
  var lastRects = null;
  var warned = false;
  var observed = [];
  var resizeObserver = win.ResizeObserver ? new win.ResizeObserver(schedule) : null;

  function collect() {
    var elements = Array.prototype.slice.call(doc.querySelectorAll(selector));
    if (resizeObserver && (elements.length !== observed.length ||
        elements.some(function (element, index) { return element !== observed[index]; }))) {
      resizeObserver.disconnect();
      if (doc.documentElement) resizeObserver.observe(doc.documentElement);
      elements.forEach(function (element) { resizeObserver.observe(element); });
    }
    observed = elements;
    var dpr = win.devicePixelRatio || 1;
    var rects = [];
    elements.forEach(function (element) {
      var style = win.getComputedStyle(element);
      if (style.pointerEvents === 'none' || style.visibility === 'hidden' ||
          style.visibility === 'collapse') return;
      var bounds = element.getBoundingClientRect();
      var left = Math.max(0, bounds.left);
      var top = Math.max(0, bounds.top);
      var right = Math.min(win.innerWidth, bounds.right);
      var bottom = Math.min(win.innerHeight, bounds.bottom);
      for (var ancestor = element; ancestor; ancestor = ancestor.parentElement) {
        var css = win.getComputedStyle(ancestor);
        if (css.display === 'none' || css.opacity === '0' || ancestor.hidden) return;
        if (ancestor !== element) {
          var clip = ancestor.getBoundingClientRect();
          if (/^(hidden|clip|scroll|auto)$/.test(css.overflowX)) {
            left = Math.max(left, clip.left); right = Math.min(right, clip.right);
          }
          if (/^(hidden|clip|scroll|auto)$/.test(css.overflowY)) {
            top = Math.max(top, clip.top); bottom = Math.min(bottom, clip.bottom);
          }
        }
      }
      if (right <= left || bottom <= top) return;
      var x = Math.floor(left * dpr);
      var y = Math.floor(top * dpr);
      var rect = { x: x, y: y, width: Math.ceil(right * dpr) - x, height: Math.ceil(bottom * dpr) - y };
      if (rects.some(function (existing) { return contains(existing, rect); })) return;
      rects = rects.filter(function (existing) { return !contains(rect, existing); });
      rects.push(rect);
    });
    if (rects.length > 50) {
      // Never silently drop controls: temporarily keep the whole viewport in WebView.
      if (!warned) win.console.warn('Mapbox: more than 50 overlay regions. Group controls with map-touch-region; map gestures are temporarily disabled.');
      warned = true;
      return [{ x: 0, y: 0, width: Math.ceil(win.innerWidth * dpr), height: Math.ceil(win.innerHeight * dpr) }];
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
      'role', 'data-button', 'data-map-touch-region', 'contenteditable']
  });
  var events = ['transitionrun', 'transitionend', 'transitioncancel', 'animationstart', 'animationend', 'animationcancel', 'load'];
  events.forEach(function (name) { doc.addEventListener(name, schedule, true); });
  win.addEventListener('resize', schedule);
  win.addEventListener('scroll', schedule, true);
  win.addEventListener('pagehide', stop);

  function stop() {
    stopped = true;
    observer.disconnect();
    if (resizeObserver) resizeObserver.disconnect();
    if (frame !== null) win.cancelAnimationFrame(frame);
    if (retry !== null) win.clearTimeout(retry);
    events.forEach(function (name) { doc.removeEventListener(name, schedule, true); });
    win.removeEventListener('resize', schedule);
    win.removeEventListener('scroll', schedule, true);
    win.removeEventListener('pagehide', stop);
  }

  return { stop: stop, ready: update() };
};
