/**
 * Comserv per-user preferences — DB-backed with localStorage offline cache.
 * Pending changes sync when back online (POST /user/prefs).
 */
(function (global) {
    'use strict';

    var LS_CACHE        = 'comserv_user_prefs';
    var LS_PENDING      = 'comserv_user_prefs_pending';
    var LS_LEGACY_COLORS = 'gcal_site_color_overrides';
    var LS_LEGACY_LANE   = 'gcal_fixed_lane_pct';

    var PREF_SITE_COLORS = 'calendar.site_colors';
    var PREF_FIXED_LANE  = 'calendar.fixed_lane_pct';
    var PREF_THEME       = 'ui.theme_override';

    var _cache = null;
    var _readyPromise = null;
    var _syncTimer = null;
    var _endpoint = '/user/prefs';

    function lsGet(key) {
        try {
            var raw = localStorage.getItem(key);
            return raw ? JSON.parse(raw) : null;
        } catch (e) {
            return null;
        }
    }

    function lsSet(key, val) {
        try {
            localStorage.setItem(key, JSON.stringify(val));
        } catch (e) { /* private mode / quota */ }
    }

    function ensureCache() {
        if (_cache === null) {
            _cache = lsGet(LS_CACHE) || {};
        }
        return _cache;
    }

    function get(key) {
        var c = ensureCache();
        return Object.prototype.hasOwnProperty.call(c, key) ? c[key] : undefined;
    }

    function getAll() {
        return Object.assign({}, ensureCache());
    }

    function setLocal(key, value) {
        ensureCache();
        if (value === undefined || value === null) {
            delete _cache[key];
        } else {
            _cache[key] = value;
        }
        lsSet(LS_CACHE, _cache);
        var pending = lsGet(LS_PENDING) || {};
        if (value === undefined || value === null) {
            delete pending[key];
        } else {
            pending[key] = value;
        }
        lsSet(LS_PENDING, pending);
    }

    function syncToServer() {
        var pending = lsGet(LS_PENDING);
        if (!pending || !Object.keys(pending).length) {
            return Promise.resolve(getAll());
        }
        return fetch(_endpoint, {
            method: 'POST',
            credentials: 'same-origin',
            headers: {
                'Content-Type': 'application/json',
                'X-Requested-With': 'XMLHttpRequest'
            },
            body: JSON.stringify({ prefs: pending })
        }).then(function (r) {
            if (r.status === 401) {
                return getAll();
            }
            return r.json();
        }).then(function (d) {
            if (d && d.ok) {
                lsSet(LS_PENDING, {});
                if (d.prefs && typeof d.prefs === 'object') {
                    _cache = Object.assign({}, d.prefs);
                    lsSet(LS_CACHE, _cache);
                }
            }
            return getAll();
        }).catch(function () {
            return getAll();
        });
    }

    function scheduleSync() {
        if (_syncTimer) {
            clearTimeout(_syncTimer);
        }
        _syncTimer = setTimeout(function () {
            _syncTimer = null;
            syncToServer();
        }, 400);
    }

    function set(key, value) {
        setLocal(key, value);
        scheduleSync();
        return value;
    }

    function migrateLegacy() {
        var legacyColors = lsGet(LS_LEGACY_COLORS);
        if (legacyColors && typeof legacyColors === 'object' && get(PREF_SITE_COLORS) === undefined) {
            setLocal(PREF_SITE_COLORS, legacyColors);
        }
        var legacyLane = parseFloat(localStorage.getItem(LS_LEGACY_LANE));
        if (!isNaN(legacyLane) && legacyLane >= 8 && legacyLane <= 45 && get(PREF_FIXED_LANE) === undefined) {
            setLocal(PREF_FIXED_LANE, legacyLane);
        }
    }

    function loadFromServer() {
        return fetch(_endpoint, {
            credentials: 'same-origin',
            headers: { 'X-Requested-With': 'XMLHttpRequest' }
        }).then(function (r) {
            if (r.status === 401) {
                migrateLegacy();
                return getAll();
            }
            return r.json();
        }).then(function (d) {
            ensureCache();
            if (d && d.ok && d.prefs && typeof d.prefs === 'object') {
                var pending = lsGet(LS_PENDING) || {};
                _cache = Object.assign({}, d.prefs, pending);
                lsSet(LS_CACHE, _cache);
            } else {
                migrateLegacy();
            }
            var pendingKeys = lsGet(LS_PENDING);
            if (pendingKeys && Object.keys(pendingKeys).length) {
                return syncToServer();
            }
            return getAll();
        }).catch(function () {
            migrateLegacy();
            return getAll();
        });
    }

    function ready() {
        if (!_readyPromise) {
            _readyPromise = loadFromServer();
        }
        return _readyPromise;
    }

    global.ComservUserPrefs = {
        get: get,
        getAll: getAll,
        set: set,
        ready: ready,
        sync: syncToServer,
        PREF_SITE_COLORS: PREF_SITE_COLORS,
        PREF_FIXED_LANE: PREF_FIXED_LANE,
        PREF_THEME: PREF_THEME
    };
})(typeof window !== 'undefined' ? window : this);