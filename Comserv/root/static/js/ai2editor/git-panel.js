// static/js/ai2editor/git-panel.js
// Detach / Attach for the AI2 left Git panel — opens /admin/git?embed=1 in a
// popup window (mirrors chat.js detach, but via URL iframe rather than DOM move).
(function () {
    'use strict';

    var _detached = false;
    var _win = null;
    var _poll = null;

    function setBtn(detached) {
        var btn = document.getElementById('ai-git-detach');
        if (btn) {
            btn.textContent = detached ? '⊞ Attach' : '⤢ Detach';
            btn.title = detached
                ? 'Close detached window and show Git in the editor'
                : 'Open Git dashboard in its own window';
        }
    }

    function closeGitPanel() {
        if (window.AI2Sidebar && typeof window.AI2Sidebar.closePanel === 'function') {
            window.AI2Sidebar.closePanel('git');
            return;
        }
        var icon = document.querySelector('#sidebar-icons .sidebar-icon[data-panel="git"]');
        if (icon && icon.classList.contains('active')) icon.click();
    }

    function openGitPanel() {
        if (window.AI2Sidebar && typeof window.AI2Sidebar.openPanel === 'function') {
            window.AI2Sidebar.openPanel('git');
            return;
        }
        var icon = document.querySelector('#sidebar-icons .sidebar-icon[data-panel="git"]');
        if (icon && !icon.classList.contains('active')) icon.click();
    }

    function clearDetachedState() {
        _detached = false;
        _win = null;
        if (_poll) {
            clearInterval(_poll);
            _poll = null;
        }
        setBtn(false);
    }

    function startClosedPoll() {
        if (_poll) clearInterval(_poll);
        _poll = setInterval(function () {
            if (!_win || _win.closed) {
                // User closed the popup — clear state; do NOT auto-reopen panel.
                clearDetachedState();
            }
        }, 700);
    }

    function openDetachedWindow() {
        var w = null;
        try {
            w = window.open(
                '/admin/git?embed=1',
                'AI2GitDetach',
                'width=960,height=720,left=80,top=40,resizable=yes,scrollbars=yes'
            );
        } catch (e) {
            console.error('[AI2GitPanel] window.open blocked', e);
            return false;
        }
        if (!w) {
            // Popup blocked — leave the in-editor panel open and do not flip state.
            console.warn('[AI2GitPanel] popup blocked; keeping panel open');
            return false;
        }
        _win = w;
        _detached = true;
        setBtn(true);
        closeGitPanel();
        startClosedPoll();
        try { w.focus(); } catch (e2) { /* ignore */ }
        return true;
    }

    function attach() {
        if (_win && !_win.closed) {
            try { _win.close(); } catch (e) { /* ignore */ }
        }
        clearDetachedState();
        openGitPanel();
    }

    function onDetachClick() {
        try {
            if (!_detached) {
                if (_win && !_win.closed) {
                    try { _win.focus(); } catch (e) { /* ignore */ }
                    _detached = true;
                    setBtn(true);
                    closeGitPanel();
                    startClosedPoll();
                    return;
                }
                openDetachedWindow();
            } else {
                attach();
            }
        } catch (e) {
            console.error('[AI2GitPanel] detach toggle error', e);
            clearDetachedState();
        }
    }

    function wire() {
        var btn = document.getElementById('ai-git-detach');
        if (!btn) return;
        btn.addEventListener('click', onDetachClick);
        console.log('%c[AI2] git-panel ready', 'color:#0a0');
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', wire);
    } else {
        wire();
    }
})();
