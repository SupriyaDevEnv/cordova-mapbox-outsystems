var exec = require('cordova/exec');

var SERVICE = 'MapboxPlugin';

function call(action, args) {
  return new Promise(function (resolve, reject) {
    try {
      var json = JSON.stringify(args || []);
      if (json.length > 4 * 1024 * 1024) throw new Error('Map input exceeds the 4 MiB limit.');
      var options = (args || [])[0] || {};
      if (action === 'downloadOfflineRegion' || action === 'downloadOfflineRegionForRect') {
        var minZoom = options.minZoom === undefined ? 10 : Number(options.minZoom);
        var maxZoom = options.maxZoom === undefined ? 16 : Number(options.maxZoom);
        if (!isFinite(minZoom) || !isFinite(maxZoom) || minZoom < 2 || maxZoom > 18 || minZoom > maxZoom) {
          throw new Error('Offline zoom must be between 2 and 18 with minZoom <= maxZoom.');
        }
      }
    } catch (error) {
      reject(error);
      return;
    }
    exec(resolve, reject, SERVICE, action, args || []);
  });
}

var api = {
  diagnostic: function () {
    var result = {
      cordova: !!window.cordova,
      service: SERVICE,
      pluginObject: !!window.MapboxPlugin,
      plugins: []
    };

    try {
      var pluginList = cordova.require('cordova/plugin_list');
      result.plugins = pluginList.map(function (plugin) {
        return {
          id: plugin.id,
          pluginId: plugin.pluginId,
          clobbers: plugin.clobbers || []
        };
      });
    } catch (e) {
      result.pluginListError = e && e.message ? e.message : String(e);
    }

    return result;
  },

  initialize: function (options) {
    options = options || {};
    delete options.token;
    return call('initialize', [options]);
  },

  ping: function () {
    return call('ping', []);
  },

  getMapboxVersion: function (success, error) {
    exec(success, error, SERVICE, 'getMapboxVersion', []);
  },

  setCamera: function (options) {
    return call('setCamera', [options || {}]);
  },

  flyTo: function (options) {
    return call('flyTo', [options || {}]);
  },

  setViewport: function (options) {
    return call('setViewport', [options || {}]);
  },

  resizeMap: function (options) {
    return call('resizeMap', [options || {}]);
  },

  setTouchableRects: function (rects) {
    return call('setTouchableRects', [rects || []]);
  },

  enableUserLocation: function () {
    return call('enableUserLocation', []);
  },

  setDeviceHeadingEnabled: function (options) {
    return call('setDeviceHeadingEnabled', [options || {}]);
  },

  setHeadingFollowMode: function (options) {
    return call('setHeadingFollowMode', [options || {}]);
  },

  setUserTrackingEnabled: function (options) {
    return call('setUserTrackingEnabled', [options || {}]);
  },

  moveToCurrentLocation: function (options) {
    return call('moveToCurrentLocation', [options || {}]);
  },

  downloadOfflineRegion: function (options) {
    return call('downloadOfflineRegion', [options || {}]);
  },

  downloadOfflineRegionForRect: function (options) {
    return call('downloadOfflineRegionForRect', [options || {}]);
  },

  showOfflineRegion: function (options) {
    return call('showOfflineRegion', [options || {}]);
  },

  deleteOfflineRegion: function (options) {
    return call('deleteOfflineRegion', [options || {}]);
  },

  onOfflineDownloadProgress: function (callback, errorCallback) {
    exec(callback, errorCallback || function () {}, SERVICE, 'registerOfflineDownloadProgressCallback', []);
  },

  setWaypointSelectionEnabled: function (options) {
    return call('setWaypointSelectionEnabled', [options || {}]);
  },

  onWaypointSelected: function (callback, errorCallback) {
    exec(callback, errorCallback || function () {}, SERVICE, 'registerWaypointSelectedCallback', []);
  },

  onMarkerClick: function (callback, errorCallback) {
    exec(callback, errorCallback || function () {}, SERVICE, 'registerMarkerClickCallback', []);
  },

  onTrackingStatusChanged: function (callback, errorCallback) {
    exec(callback, errorCallback || function () {}, SERVICE, 'registerTrackingStatusCallback', []);
  },

  onLocationAccuracyChanged: function (callback, errorCallback) {
    exec(
      callback,
      errorCallback || function () {},
      SERVICE,
      'registerLocationAccuracyCallback',
      []
    );
  },

  addMarker: function (options) {
    return call('addMarker', [options || {}]);
  },

  loadMarkers: function (markers, options) {
    options = options || {};
    options.markers = markers || [];
    var MAX_MARKERS = 10000;
    if (options.markers.length > MAX_MARKERS) {
      return Promise.reject(new Error('Too many markers: maximum allowed is ' + MAX_MARKERS + '.'));
    }
    return call('loadMarkers', [options]);
  },

  removeMarker: function (id) {
    return call('removeMarker', [{ id: id }]);
  },

  clearMarkers: function () {
    return call('clearMarkers', []);
  },

  loadBoundaries: function (boundaries, options) {
    options = options || {};
    if (typeof boundaries === 'string') {
      if (boundaries.length > 4 * 1024 * 1024) return Promise.reject(new Error('Boundary input is too large.'));
      try {
        boundaries = JSON.parse(boundaries);
      } catch (error) {
        return Promise.reject(new Error(
          'Failed to parse boundaries: ' + (error.message || 'Invalid JSON.')
        ));
      }
    }
    if (!Array.isArray(boundaries)) {
      return Promise.reject(new Error('Boundaries must be a JSON string or an array.'));
    }
    var MAX_BOUNDARIES = 1000;
    if (boundaries.length > MAX_BOUNDARIES) {
      return Promise.reject(new Error('Too many boundaries: maximum allowed is ' + MAX_BOUNDARIES + '.'));
    }
    var vertices = 0;
    for (var i = 0; i < boundaries.length; i++) {
      var geometry = boundaries[i] && boundaries[i].geometry;
      vertices += Array.isArray(geometry) ? geometry.length : 0;
      if (vertices > 20000) return Promise.reject(new Error('Too many boundary vertices: maximum total is 20000.'));
    }
    options.boundaries = boundaries;
    return call('loadBoundaries', [options]);
  },

  setBoundaryVisibility: function (options) {
    return call('setBoundaryVisibility', [options || {}]);
  },

  setLayerVisibility: function (options) {
    return call('setLayerVisibility', [options || {}]);
  },

  getLayerIds: function () {
    return call('getLayerIds', []);
  },

  clearBoundaries: function () {
    return call('clearBoundaries', []);
  },

  getCamera: function () {
    return call('getCamera', []);
  },

  getCurrentLocationAccuracy: function () {
    return call('getCurrentLocationAccuracy', []);
  },

  close: function () {
    return call('close', []);
  },

  setMapStyle: function (options) {
    return call('setMapStyle', [options || {}]);
  },

  startPathTracking: function (options) {
    return call('startPathTracking', [options || {}]);
  },

  stopPathTracking: function () {
    return call('stopPathTracking', []);
  },

  loadPath: function (pathData, options) {
    options = options || {};
    if (typeof pathData === 'string') {
      if (pathData.length > 4 * 1024 * 1024) return Promise.reject(new Error('Path input is too large.'));
      try {
        pathData = JSON.parse(pathData);
      } catch (error) {
        return Promise.reject(new Error(
          'Failed to parse path data: ' + (error.message || 'Invalid JSON.')
        ));
      }
    }
    if (!pathData || !Array.isArray(pathData.points)) {
      return Promise.reject(new Error('Path data must have a "points" array.'));
    }
    if (pathData.points.length < 2 || pathData.points.length > 20000) {
      return Promise.reject(new Error('A path requires between 2 and 20000 points.'));
    }
    options.points = pathData.points;
    return call('loadPath', [options]);
  },

  clearPaths: function () {
    return call('clearPaths', []);
  },

  setPathVisibility: function (options) {
    return call('setPathVisibility', [options || {}]);
  }
};

if (typeof window !== 'undefined') {
  window.MapboxPlugin = window.MapboxPlugin || api;
}

module.exports = api;
