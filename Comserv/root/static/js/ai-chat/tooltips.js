// ai-chat/tooltips.js — SHARED hover-tooltip map for every chat button.
//
// Some chat buttons already carry a title; this module guarantees ALL of them
// do, from one central place (DRY — no per-button title strings scattered
// across templates/widgets). Any widget calls ComservChat.tooltips.apply(rootEl)
// after building its DOM; we set `title` on every known button selector.
//
// Loaded before the widgets via js_load.tt. Attaches to window.ComservChat.tooltips.
(function () {
    'use strict';
    window.ComservChat = window.ComservChat || {};

    // Selector -> tooltip text. Selectors are matched within the passed root.
    // IDs/classes used across the general widget and the editor chat.
    var MAP = {
        '#ai-provider':               'Choose the AI model for this chat (hy3 is the default coding model)',
        '#model-select':              'Choose the AI model for this chat (hy3 is the default coding model)',
        '#ai-chat-send':               'Send your message to the AI',
        '#message-input':              'Type your message — Ctrl+V pastes an image',
        '#send-message':              'Send your message to the AI',
        '#mic-record-btn':            'Record a voice note or dictate your message',
        '#attach-image-btn':          'Attach an image (or paste with Ctrl+V) for the AI to see',
        '#attach-audio-btn':          'Upload an audio file for transcription',
        '#image-file-input':          'Choose an image to attach',
        '#audio-file-input':          'Choose an audio file to transcribe',
        '#ai-chat-detach':            'Detach this chat into its own window (frees editor space); click again to re-attach',
        '#ai-chat-resize':            'Drag to resize the chat sidebar',
        '#ai-chat-clear':             'Clear the conversation',
        '#ai-chat-todo':              'Add a todo for this page’s project',
        '#toggle-history-btn':        'Show/hide past conversations',
        '#conversations-link':        'Browse saved conversations',
        '#web-search-toggle':         'Enable web search for Grok requests (uses API credits)',
        '#agent-select':              'Pick the AI agent / persona for this chat',
        '#ai-approve-btn':            'Apply the AI’s suggested code change to the editor',
        '#ai-reject-btn':             'Discard the AI’s suggested code change',
        '#ai-diff-pane':              'Proposed code change — Approve to apply, Reject to discard',
        '#branch-select':             'Active git branch for this editor session',
        '#editor-select':             'Switch the editor (Ace code / Rich text)',
        '#refresh-btn':               'Reload the file from disk',
        '#merge-main-btn':            'Merge the current branch into main'
    };

    function apply(rootEl) {
        var root = rootEl || document;
        Object.keys(MAP).forEach(function (sel) {
            try {
                var el = root.querySelector(sel);
                if (el && !el.getAttribute('title')) el.setAttribute('title', MAP[sel]);
            } catch (e) { /* selector not valid in this widget — ignore */ }
        });
        // Also tag any element that already declares data-tip (override hook).
        var tagged = root.querySelectorAll('[data-tip]');
        for (var i = 0; i < tagged.length; i++) {
            tagged[i].setAttribute('title', tagged[i].getAttribute('data-tip'));
        }
    }

    window.ComservChat.tooltips = { apply: apply, MAP: MAP };
})();
