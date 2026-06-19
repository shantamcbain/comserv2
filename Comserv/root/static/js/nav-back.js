/**
 * Nav Back — client-side history stack; rewrites Back link href on every page load.
 */
(function () {
    'use strict';

    var path = window.location.pathname + window.location.search;

    function storageKey() {
        return 'comserv_nav_v2_' + (window.location.hostname || 'default');
    }

    function readHist() {
        try {
            var raw = sessionStorage.getItem(storageKey());
            return raw ? JSON.parse(raw) : [];
        } catch (e) {
            return [];
        }
    }

    function writeHist(list) {
        try {
            sessionStorage.setItem(storageKey(), JSON.stringify(list.slice(-30)));
        } catch (e) { /* ignore */ }
    }

    function refPath() {
        var ref = document.referrer;
        if (!ref) return null;
        try {
            var u = new URL(ref);
            if (u.hostname !== window.location.hostname) return null;
            var p = u.pathname + u.search;
            return p && p !== path ? p : null;
        } catch (e) {
            return null;
        }
    }

    function recordVisit() {
        var hist = readHist();
        if (hist.length && hist[hist.length - 1] === path) {
            return;
        }
        if (hist.length >= 2 && hist[hist.length - 2] === path) {
            hist.pop();
        } else {
            hist.push(path);
        }
        writeHist(hist);
    }

    function previousUrl() {
        var hist = readHist();
        if (hist.length >= 2) {
            return hist[hist.length - 2];
        }
        return refPath() || '/';
    }

    function updateBackLinks() {
        var target = previousUrl();
        if (!target || target === path) {
            target = refPath() || '/';
        }
        document.querySelectorAll('[data-nav-back]').forEach(function (a) {
            a.href = target;
            a.setAttribute('title', 'Back to ' + target);
        });
    }

    recordVisit();
    updateBackLinks();

    window.addEventListener('pageshow', function () {
        updateBackLinks();
    });

    document.addEventListener('click', function (e) {
        var link = e.target && e.target.closest ? e.target.closest('[data-nav-back]') : null;
        if (!link) return;

        var target = previousUrl();
        if (!target || target === path) {
            target = refPath();
        }
        if (target && target !== path) {
            e.preventDefault();
            window.location.href = target;
            return;
        }
        if (window.history.length > 1) {
            e.preventDefault();
            window.history.back();
        }
    });
})();