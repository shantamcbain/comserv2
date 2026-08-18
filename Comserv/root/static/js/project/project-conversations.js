/*
 * project/project-conversations.js
 * --------------------------------------------------------------------------
 * Delegated loader for the "AI Chat Activity" panel on /project/details.
 *
 * The old implementation lived as a raw inline <script> in
 * root/todo/projectdetails.tt (a v2-compliance violation — inline <script>
 * is banned in any template that includes js_load.tt). This module replaces
 * it with data-* delegation: it binds to the [data-project-id] container
 * (#ai-project-conversations) that the template already emits, so there is
 * no per-page inline JS and the module is cached/versioned like every other
 * feature file.
 *
 * Loaded only on /project/ routes via root/js_load.tt (defer).
 * --------------------------------------------------------------------------
 */
(function () {
    'use strict';

    function renderConversations(el, data) {
        if (!data || !data.success || !data.conversations || !data.conversations.length) {
            el.innerHTML = '<p class="text-muted" style="font-size:0.9em;margin:0;">' +
                'No AI conversations for this project yet.</p>';
            return;
        }
        var html = '<ul class="mb-0" style="padding-left:18px;margin:0;">';
        data.conversations.forEach(function (c) {
            var title = (c.title || 'Untitled').replace(/</g, '&lt;').replace(/>/g, '&gt;');
            html += '<li>' +
                '<a href="/ai/conversation/' + encodeURIComponent(c.id) + '">' + title + '</a>' +
                ' <span class="text-muted" style="font-size:0.85em;">(' +
                (c.model || 'unknown') + ' &mdash; ' + (c.updated_at || '') + ')</span></li>';
        });
        html += '</ul>';
        el.innerHTML = html;
    }

    function load(el) {
        var projId = el.getAttribute('data-project-id');
        if (!projId) {
            return;
        }
        fetch('/ai/project_conversations?project_id=' + encodeURIComponent(projId))
            .then(function (r) { return r.json(); })
            .then(function (d) { renderConversations(el, d); })
            .catch(function () {
                el.innerHTML = '<p class="text-muted" style="font-size:0.9em;margin:0;">' +
                    'Could not load conversations.</p>';
            });
    }

    function init() {
        var el = document.getElementById('ai-project-conversations');
        if (el) {
            load(el);
        }
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
