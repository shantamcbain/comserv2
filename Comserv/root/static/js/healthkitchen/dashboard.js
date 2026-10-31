/* Health Kitchen dashboard: check off an activity without a full reload.
   The form still submits if fetch fails. */
(function () {
    'use strict';

    document.addEventListener('change', function (ev) {
        var box = ev.target;
        if (!box || !box.classList || !box.classList.contains('hk-activity-done')) {
            return;
        }
        var form = box.closest('form');
        if (!form) {
            return;
        }
        var data = new FormData(form);
        data.set('done', box.checked ? '1' : '0');
        data.set('ajax', '1');
        fetch(form.action, {
            method: 'POST',
            body: data,
            credentials: 'same-origin',
            headers: { 'Accept': 'application/json' }
        }).then(function (r) {
            return r.json().then(function (d) {
                if (!r.ok || !d.ok) {
                    throw new Error(d.error || 'save failed');
                }
                return d;
            });
        }).then(function (d) {
            form.classList.toggle('hk-activity-is-done', !!d.done);
        }).catch(function () {
            form.submit();
        });
    });
}());
