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

  function run(name, promise) {
    log('CALL ' + name);
    Promise.resolve(promise).then(function (result) {
      log('OK ' + name, result);
    }).catch(function (error) {
      var message = error && error.message ? error.message : error;
      log('ERROR ' + name, message);
    });
  }

  function fail(name) {
    return function (error) {
      var message = error && error.message ? error.message : error;
      log('ERROR ' + name, message);
    };
  }

  document.addEventListener('deviceready', function () {
    statusEl = document.getElementById('status');
    statusEl.textContent = 'Cordova ready. MapboxPlugin=' + (typeof MapboxPlugin);

    if (typeof MapboxPlugin === 'undefined') {
      log('ERROR', 'MapboxPlugin is not available.');
      return;
    }

    MapboxPlugin.onLocationAccuracyChanged(function (data) {
      log('EVENT locationAccuracy', data);
    }, fail('onLocationAccuracyChanged'));

    MapboxPlugin.onTrackingStatusChanged(function (data) {
      log('EVENT trackingStatus', data);
    }, fail('onTrackingStatusChanged'));

    document.getElementById('initialize').onclick = function () {
      var mapHeight = 140;
      var mapY = Math.max(0, window.innerHeight - mapHeight);
      run('initialize', MapboxPlugin.initialize({
        inline: true,
        behindWebView: true,
        x: 0,
        y: mapY,
        width: Math.max(1, window.innerWidth),
        height: mapHeight,
        latitude: 17.3850,
        longitude: 78.4867,
        zoom: 12
      }));
    };

    document.getElementById('enableLocation').onclick = function () {
      run('enableUserLocation', MapboxPlugin.enableUserLocation());
    };

    document.getElementById('moveLocation').onclick = function () {
      run('moveToCurrentLocation', MapboxPlugin.moveToCurrentLocation({ zoom: 16 }));
    };

    document.getElementById('accuracy').onclick = function () {
      run('getCurrentLocationAccuracy', MapboxPlugin.getCurrentLocationAccuracy());
    };

    document.getElementById('trackingOn').onclick = function () {
      run('trackingOn', MapboxPlugin.setUserTrackingEnabled({ enabled: true }));
    };

    document.getElementById('trackingOff').onclick = function () {
      run('trackingOff', MapboxPlugin.setUserTrackingEnabled({ enabled: false }));
    };

    document.getElementById('clearLog').onclick = function () {
      statusEl.textContent = 'Log cleared.';
    };
  }, false);
}());
