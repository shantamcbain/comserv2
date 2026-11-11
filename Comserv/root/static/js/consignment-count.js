/* Consignment photo count — wait for the background read.
 *
 * The vision pass runs in script/consignment_count_worker.pl, not in the request
 * (a CPU read of a 7B model would block the single web worker). The review page
 * renders data-read-poll="1" while the count row is still status='reading', so
 * this module simply refreshes until the text lands or the read fails.
 */
(function () {
    'use strict';

    var POLL_MS = 4000;

    function init() {
        var host = document.querySelector('[data-read-poll="1"]');
        if (!host) { return; }
        window.setTimeout(function () {
            window.location.reload();
        }, POLL_MS);
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
