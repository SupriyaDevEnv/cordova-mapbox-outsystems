var exec = require('cordova/exec');

var SERVICE = 'MapboxPlugin';

function call(action, args) {
  return new Promise(function (resolve, reject) {
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
    options.boundaries = boundaries;
    return call('loadBoundaries', [options]);
  },

  setBoundaryVisibility: function (options) {
    return call('setBoundaryVisibility', [options || {}]);
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
  }
};

if (typeof window !== 'undefined') {
  window.MapboxPlugin = window.MapboxPlugin || api;
}

module.exports = api;
