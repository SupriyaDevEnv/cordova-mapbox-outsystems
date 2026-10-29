const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

test('audit: close during touch setup must cancel the whole initialization', async () => {
  const calls = [];
  let ready;
  const touchReady = new Promise(resolve => { ready = resolve; });
  const context = {
    module: { exports: {} },
    window: { cordova: { platformId: 'android' } },
    require(name) {
      if (name === 'cordova/exec') return (ok, fail, service, action) => calls.push({ok, fail, action});
      if (name === './AndroidTouchRegions') return () => ({ready: touchReady, stop() {}});
      throw new Error(name);
    }
  };
  vm.runInNewContext(fs.readFileSync('www/MapboxPlugin.js', 'utf8'), context);
  const api = context.module.exports;
  const init = api.initialize({behindWebView: true});
  const outcome = init.then(() => 'resolved', e => api.isCancellationError(e) ? 'cancelled' : 'other-error');
  calls.find(c => c.action === 'initialize').ok({status: 'initialized'});
  await Promise.resolve();
  const close = api.close();
  calls.find(c => c.action === 'close').ok();
  await close;
  ready();
  assert.equal(await outcome, 'cancelled');
});
