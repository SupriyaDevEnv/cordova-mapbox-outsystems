(function () {
  var statusEl;

  function log(label, value) {
    if (!statusEl) return;
    var text = label;
    if (value !== undefined) {
      try {
        text += ': ' + (typeof value === 'string' ? value : JSON.stringify(value));
      } catch (e) {
        text += ': ' + String(value);
      }
    }
    statusEl.textContent += '\n' + text;
    statusEl.scrollTop = statusEl.scrollHeight;
  }

  function ok(name) {
    return function (result) { log('OK ' + name, result); };
  }

  function fail(name) {
    return function (error) { log('ERROR ' + name, error); };
  }

  document.addEventListener('deviceready', function () {
    statusEl = document.getElementById('status');
    statusEl.textContent = 'Cordova ready. MapboxPlugin=' + (typeof MapboxPlugin);

    MapboxPlugin.onLocationAccuracyChanged(function (data) {
      log('EVENT locationAccuracy', data);
    }, fail('onLocationAccuracyChanged'));

    MapboxPlugin.onTrackingStatusChanged(function (data) {
      log('EVENT trackingStatus', data);
    }, fail('onTrackingStatusChanged'));

    document.getElementById('initialize').onclick = function () {
      MapboxPlugin.initialize({
        inline: true,
        behindWebView: true,
        x: 0,
        y: 460,
        width: Math.max(1, window.innerWidth),
        height: 360,
        latitude: 17.3850,
        longitude: 78.4867,
        zoom: 12
      }, ok('initialize'), fail('initialize'));
    };

    document.getElementById('enableLocation').onclick = function () {
      MapboxPlugin.enableUserLocation(ok('enableUserLocation'), fail('enableUserLocation'));
    };

    document.getElementById('moveLocation').onclick = function () {
      MapboxPlugin.moveToCurrentLocation({ zoom: 16 }, ok('moveToCurrentLocation'), fail('moveToCurrentLocation'));
    };

    document.getElementById('accuracy').onclick = function () {
      MapboxPlugin.getCurrentLocationAccuracy(ok('getCurrentLocationAccuracy'), fail('getCurrentLocationAccuracy'));
    };

    document.getElementById('trackingOn').onclick = function () {
      MapboxPlugin.setUserTrackingEnabled({ enabled: true }, ok('trackingOn'), fail('trackingOn'));
    };

    document.getElementById('trackingOff').onclick = function () {
      MapboxPlugin.setUserTrackingEnabled({ enabled: false }, ok('trackingOff'), fail('trackingOff'));
    };

    document.getElementById('clearLog').onclick = function () {
      statusEl.textContent = 'Log cleared.';
    };
  }, false);
}());
