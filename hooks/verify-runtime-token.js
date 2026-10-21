const fs = require('fs');
const path = require('path');

function decode(value) {
  return value.replace(/&(#x[0-9a-f]+|#[0-9]+|amp|quot|apos|lt|gt);/gi, (_, entity) => {
    if (entity[0] === '#') {
      const hex = entity[1].toLowerCase() === 'x';
      const code = parseInt(entity.slice(hex ? 2 : 1), hex ? 16 : 10);
      if (code > 0x10ffff) throw new Error('Invalid XML character reference.');
      return String.fromCodePoint(code);
    }
    return { amp: '&', quot: '"', apos: "'", lt: '<', gt: '>' }[entity.toLowerCase()];
  });
}

function verify(xml) {
  // Remove comments, then parse all preference attributes independent of order.
  // Check every token preference, including duplicates, without logging values.
  xml = xml.replace(/<!--[\s\S]*?-->/g, '');
  for (const tag of xml.match(/<preference\b(?:[^>"']|"[^"]*"|'[^']*')*>/gi) || []) {
    const attrs = {};
    for (const match of tag.matchAll(/([\w:-]+)\s*=\s*(["'])(.*?)\2/gs)) {
      attrs[match[1].toLowerCase()] = decode(match[3]);
    }
    if ((attrs.name || '').toUpperCase() !== 'MAPBOX_ACCESS_TOKEN') continue;
    const token = (attrs.value || '').trim();
    // Unconfigured templates may be prepared before a token is supplied.
    // Native initialization fails closed until a valid public token is present.
    if (!token || token === '__MAPBOX_ACCESS_TOKEN_NOT_SET__' || token === '$MAPBOX_ACCESS_TOKEN') continue;
    if (!/^pk\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(token)) {
      throw new Error('MAPBOX_ACCESS_TOKEN must be a public pk.* token. Never package secret tokens.');
    }
  }
}

module.exports = function (context) {
  const root = path.join(context.opts.projectRoot, 'platforms');
  function visit(directory, depth) {
    if (!fs.existsSync(directory) || depth > 7) return;
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      if (entry.isSymbolicLink()) continue;
      const full = path.join(directory, entry.name);
      if (entry.isDirectory() && !['Pods', 'build', 'node_modules', '.git'].includes(entry.name)) {
        visit(full, depth + 1);
      } else if (entry.isFile() && entry.name === 'config.xml') {
        verify(fs.readFileSync(full, 'utf8'));
      }
    }
  }
  visit(path.join(root, 'android'), 0);
  visit(path.join(root, 'ios'), 0);
};
module.exports.verify = verify;
