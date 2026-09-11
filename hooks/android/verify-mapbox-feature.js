#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

module.exports = function (context) {
  const projectRoot = context.opts.projectRoot;
  const configPath = path.join(
    projectRoot,
    'platforms',
    'android',
    'app',
    'src',
    'main',
    'res',
    'xml',
    'config.xml'
  );

  if (!fs.existsSync(configPath)) {
    console.log('[MapboxPlugin] Android config.xml not found at: ' + configPath);
    return;
  }

  const config = fs.readFileSync(configPath, 'utf8');
  const hasService = config.indexOf('feature name="MapboxPlugin"') >= 0;
  const hasClass = config.indexOf('com.outsystems.mapbox.MapboxPluginPermissionEntry') >= 0;

  console.log('[MapboxPlugin] Android config.xml feature present: ' + hasService);
  console.log('[MapboxPlugin] Android config.xml class present: ' + hasClass);

  if (!hasService || !hasClass) {
    console.log('[MapboxPlugin] Expected feature entry was not generated:');
    console.log('<feature name="MapboxPlugin">');
    console.log('  <param name="android-package" value="com.outsystems.mapbox.MapboxPluginPermissionEntry" />');
    console.log('</feature>');
  }

  const tokenPreference = config.match(
    /<preference\b[^>]*\bname=["']MAPBOX_ACCESS_TOKEN["'][^>]*\/?>/i
  );
  const hasTokenPref = Boolean(tokenPreference);
  console.log('[MapboxPlugin] Android config.xml MAPBOX_ACCESS_TOKEN present: ' + hasTokenPref);

  if (!tokenPreference) {
    return;
  }

  const tokenValueMatch = tokenPreference[0].match(/\bvalue=["']([^"']*)["']/i);
  const tokenValue = tokenValueMatch ? tokenValueMatch[1].trim() : '';

  if (tokenValue.startsWith('sk.')) {
    throw new Error(
      '[MapboxPlugin] Refusing to package a Mapbox secret token (sk.*). ' +
      'Use a public pk.* access token for mobile applications and rotate any secret token that was previously embedded.'
    );
  }
};
