const test = require('node:test');
const assert = require('node:assert');
const { verify } = require('../hooks/verify-runtime-token.js');

const pref = (value) => `<widget><preference name="MAPBOX_ACCESS_TOKEN" value="${value}" /></widget>`;

test('accepts a public pk token', () => {
  assert.doesNotThrow(() => verify(pref('pk.abc123.def_456-x')));
});

test('accepts attributes in any order', () => {
  assert.doesNotThrow(() => verify('<preference value="pk.a.b" name="MAPBOX_ACCESS_TOKEN"/>'));
});

test('rejects secret sk tokens', () => {
  assert.throws(() => verify(pref('sk.abc.def')), /public pk\.\* token/);
});

test('rejects secret tokens written with XML entities', () => {
  assert.throws(() => verify(pref('&#115;k.abc.def')));
});

test('allows unconfigured templates', () => {
  for (const value of ['', '__MAPBOX_ACCESS_TOKEN_NOT_SET__', '$MAPBOX_ACCESS_TOKEN']) {
    assert.doesNotThrow(() => verify(pref(value)));
  }
});

test('ignores tokens inside comments', () => {
  assert.doesNotThrow(() => verify(`<!-- ${pref('sk.abc.def')} -->`));
});

test('checks every duplicate preference', () => {
  assert.throws(() => verify(pref('pk.a.b') + pref('sk.a.b')));
});
