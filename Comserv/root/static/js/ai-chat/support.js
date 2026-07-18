// ai-chat/support.js — V2 module (extracted from local-chat.js)
// Live support chat: user-facing support mode (enter/exit/poll/ticket) plus the
// self-contained admin pending-support notifier (isAdmin-guarded, own DOMContentLoaded).
//
// The user-facing block reaches into the chat-core closure for `state` and
// `addMessage`, so it is exposed via ComservChat.support.wire(ctx) and called
// from local-chat.js at the spot the original block executed (defines
// window.__aiChatSupportFns used by escalation buttons). The admin notifier is
// fully self-contained and runs immediately on script load. Behavior 1:1.
(function () {
    window.ComservChat = window.ComservChat || {};

    // -- Admin pending-support notifier (self-contained) ---------------------
    (function() {
        if (!window.AI_CHAT_USER_CONFIG || !window.AI_CHAT_USER_CONFIG.isAdmin) return;
        var _adminNotifPerm = (typeof Notification !== 'undefined') ? Notification.permission : 'denied';
        var _adminLastPending = 0;
        var _adminTitleFlashTimer = null;
        var _adminOrigTitle = null;

        function _requestAdminNotifPerm() {
            if (typeof Notification === 'undefined') return;
            if (Notification.permission === 'granted') { _adminNotifPerm = 'granted'; return; }
            if (Notification.permission !== 'denied') {
                Notification.requestPermission().then(function(p) { _adminNotifPerm = p; });
            }
        }

        function _adminBeep() {
            try {
                var ctx = new (window.AudioContext || window.webkitAudioContext)();
                var osc = ctx.createOscillator();
                var gain = ctx.createGain();
                osc.connect(gain);
                gain.connect(ctx.destination);
                osc.type = 'sine';
                osc.frequency.value = 880;
                gain.gain.setValueAtTime(0.3, ctx.currentTime);
                gain.gain.exponentialRampToValueAtTime(0.001, ctx.currentTime + 0.5);
                osc.start(ctx.currentTime);
                osc.stop(ctx.currentTime + 0.5);
            } catch (e) {}
        }

        function _adminTitleFlash(n) {
            if (_adminTitleFlashTimer) return;
            if (!_adminOrigTitle) _adminOrigTitle = document.title;
            var alertTitle = '💬 ' + n + ' Support Request' + (n > 1 ? 's' : '') + '!';
            var on = true;
            var count = 0;
            _adminTitleFlashTimer = setInterval(function() {
                document.title = on ? alertTitle : _adminOrigTitle;
                on = !on;
                if (++count >= 20) {
                    clearInterval(_adminTitleFlashTimer);
                    _adminTitleFlashTimer = null;
                    document.title = _adminOrigTitle;
                }
            }, 800);
        }

        function _adminShowToast(n) {
            var existing = document.getElementById('admin-support-toast');
            if (existing) existing.parentNode.removeChild(existing);
            var toast = document.createElement('div');
            toast.id = 'admin-support-toast';
            toast.style.cssText = 'position:fixed;top:70px;right:20px;z-index:99999;background:#1a6bb5;color:#fff;'
                + 'padding:14px 20px;border-radius:8px;box-shadow:0 4px 20px rgba(0,0,0,0.3);'
                + 'font-size:.95em;font-weight:600;cursor:pointer;max-width:320px;line-height:1.4;';
            toast.innerHTML = '💬 ' + n + ' support chat request' + (n > 1 ? 's' : '') + ' awaiting reply'
                + '<br><small style="font-weight:normal;opacity:.85;">Click to open Support Chat Admin</small>';
            toast.onclick = function() {
                if (window.AI_WIDGET_POPUP && window.opener && !window.opener.closed) {
                    window.opener.location.href = '/chat/admin';
                } else {
                    window.location.href = '/chat/admin';
                }
            };
            document.body.appendChild(toast);
            setTimeout(function() {
                if (toast.parentNode) toast.parentNode.removeChild(toast);
            }, 30000);
        }

        function _checkPendingSupport() {
            fetch('/chat/pending_count', { credentials: 'include' })
            .then(function(r) { return r.json(); })
            .then(function(d) {
                var n = d && d.count ? parseInt(d.count, 10) : 0;
                if (n > 0 && n > _adminLastPending) {
                    if (_adminNotifPerm === 'granted') {
                        new Notification('💬 Support Chat: ' + n + ' request' + (n > 1 ? 's' : '') + ' awaiting reply', {
                            body: 'Open Support Chat Admin to respond.',
                            icon: '/static/images/favicon.ico',
                            tag: 'admin-support-pending',
                            requireInteraction: true
                        });
                    }
                    _adminBeep();
                    _adminTitleFlash(n);
                    _adminShowToast(n);
                }
                _adminLastPending = n;
                var badge = document.getElementById('nav-support-badge');
                if (badge) { badge.textContent = n || ''; badge.style.display = n > 0 ? '' : 'none'; }
            })
            .catch(function() {});
        }
        function _sendAdminHeartbeat() {
            fetch('/chat/admin_heartbeat', { method: 'POST', credentials: 'include' })
            .then(function(r) { return r.json(); })
            .then(function(d) { if (!d.success) console.warn('[Chat] admin_heartbeat rejected (not admin role?)'); })
            .catch(function() {});
        }

        document.addEventListener('DOMContentLoaded', function() {
            _requestAdminNotifPerm();
            _sendAdminHeartbeat();
            setTimeout(_checkPendingSupport, 2000);
            setInterval(_checkPendingSupport, 30000);
            setInterval(_sendAdminHeartbeat, 20000);
        });
    })();

    // -- User-facing support mode -------------------------------------------
    function wire(ctx) {
        var state     = ctx.state;
        var addMessage = ctx.addMessage;

    function _detectSupportNeeded(text) {
        if (/\[SUPPORT_NEEDED\]/i.test(text)) return true;
        var phrases = [
            /i\s+(don'?t|do not|cannot|can'?t)\s+(have|access|provide|help|answer|assist)/i,
            /outside\s+(my|the AI'?s?)\s+(capabilities|knowledge|scope|ability)/i,
            /please\s+contact\s+support/i,
            /you\s+('?ll?\s+)?need\s+to\s+contact/i,
            /i\s+am\s+unable\s+to\s+assist/i,
        ];
        return phrases.some(function(re) { return re.test(text); });
    }

    function _stripSupportTag(text) {
        return text.replace(/\[SUPPORT_NEEDED\]\s*/gi, '').trim();
    }

    function _sendUserHeartbeat() {
        if (!state.supportConvId) return;
        fetch('/chat/user_heartbeat', {
            method: 'POST',
            credentials: 'include',
            body: new URLSearchParams({ conversation_id: state.supportConvId })
        }).catch(function() {});
    }

    function _enterSupportMode(convId, lastMsgId, ticketNumber) {
        state.supportMode   = true;
        state.supportConvId = convId;
        state.supportLastMsgId = lastMsgId || 0;
        _sendUserHeartbeat();
        state.userHeartbeatTimer = setInterval(_sendUserHeartbeat, 30000);
        var header = document.getElementById('chat-header');
        if (header) {
            header.style.background = 'var(--accent-color, #1a6bb5)';
            header.textContent = '💬 Live Support Chat';
        }
        var placeholder = document.getElementById('message-input');
        if (placeholder) placeholder.placeholder = 'Describe your issue here…';
        var guidance = '✅ **An administrator has been notified and will join shortly.**\n\n'
            + 'Please describe your issue below — include any error messages, what you were doing, and what you expected to happen.\n\n'
            + 'If no admin responds within a few minutes you can [create a support ticket](/HelpDesk/ticket/new) instead.';
        _addSupportSystemMsg(guidance);
        _startSupportPolling();
    }

    function _exitSupportMode() {
        if (state.supportPollTimer) { clearInterval(state.supportPollTimer); state.supportPollTimer = null; }
        if (state.userHeartbeatTimer) { clearInterval(state.userHeartbeatTimer); state.userHeartbeatTimer = null; }
        state.supportMode   = false;
        state.supportConvId = null;
        state.supportLastMsgId = 0;
        var header = document.getElementById('chat-header');
        if (header) { header.style.background = ''; header.textContent = state.currentAgent ? (state.currentAgent.display_name || 'AI Assistant') : 'AI Assistant'; }
        var placeholder = document.getElementById('message-input');
        if (placeholder) placeholder.placeholder = 'Type a message…';
    }

    function _addSupportSystemMsg(text) {
        var el = document.createElement('div');
        el.className = 'message system-message';
        el.style.cssText = 'background:var(--support-msg-bg, #e8f0fe);border:1px solid var(--support-msg-border, #acc);padding:8px 14px;border-radius:6px;font-size:.85em;color:var(--support-msg-color, #1a3a6b);margin:4px 0;line-height:1.5;';
        var html = text
            .replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')
            .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
            .replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2" style="color:var(--accent-color, #1a6bb5);">$1</a>')
            .replace(/\n\n/g, '<br><br>')
            .replace(/\n/g, '<br>');
        el.innerHTML = html;
        var container = document.getElementById('chat-messages');
        if (container) { container.appendChild(el); container.scrollTop = container.scrollHeight; }
    }

    function _startSupportPolling() {
        if (state.supportPollTimer) clearInterval(state.supportPollTimer);
        state.supportPollTimer = setInterval(function() {
            if (!state.supportMode || !state.supportConvId) { clearInterval(state.supportPollTimer); return; }
            fetch('/chat/get_messages?conversation_id=' + state.supportConvId + '&last_id=' + state.supportLastMsgId, {
                credentials: 'include'
            })
            .then(function(r) { return r.json(); })
            .then(function(d) {
                if (!d.success || !d.messages) return;
                d.messages.forEach(function(msg) {
                    if (msg.id > state.supportLastMsgId) {
                        state.supportLastMsgId = msg.id;
                        if (msg.role === 'assistant') {
                            addMessage(msg.content, 'ai-message');
                        }
                    }
                });
                if (d.conv_status === 'archived') {
                    clearInterval(state.supportPollTimer);
                    state.supportPollTimer = null;
                    _addSupportSystemMsg('🔒 This support chat has been closed by the administrator. Thank you for contacting us!');
                    _exitSupportMode();
                }
            })
            .catch(function() {});
        }, 5000);
    }

    function _showNoAdminMessage() {
        var el = document.createElement('div');
        el.className = 'message system-message';
        el.style.cssText = 'background:var(--warning-bg, #fff3cd);border:1px solid var(--warning-color, #ffc107);padding:10px 14px;border-radius:6px;font-size:.85em;color:var(--warning-text, #664d03);margin:4px 0;line-height:1.6;';
        el.innerHTML = '⚠️ <strong>No administrator is currently logged in.</strong><br>'
            + 'You can submit a support ticket and an admin will respond when available:<br>'
            + '<button onclick="(function(){var _s=window.__aiChatSupportFns;if(_s)_s.ticket();})()" '
            + 'style="margin-top:8px;padding:6px 14px;background:var(--accent-color, #1a6bb5);color:var(--bg-color, #fff);border:none;border-radius:4px;cursor:pointer;font-size:.88em;">📋 Create Support Ticket</button>';
        var container = document.getElementById('chat-messages');
        if (container) { container.appendChild(el); container.scrollTop = container.scrollHeight; }
    }

    function _initSupportChat(contextMsg) {
        _addSupportSystemMsg('⏳ Checking admin availability…');
        fetch('/chat/check_admin_online', { credentials: 'include' })
        .then(function(r) { return r.json(); })
        .then(function(presence) {
            console.log('[Chat] check_admin_online:', presence);
            if (!presence.online) {
                _showNoAdminMessage();
                return;
            }
            var _rawTitle = (document.title || '').replace(/https?:\/\/[^\s|:]+[:|]?\s*/g, '').replace(/\s*[:|]\s*$/, '').trim();
            var _chatTitle = 'Support Chat — ' + (_rawTitle || window.location.pathname);
            var body = new URLSearchParams({
                message: contextMsg || 'User requested live support',
                agent_type: 'support',
                title: _chatTitle
            });
            fetch('/chat/send_message', { method: 'POST', credentials: 'include', body: body })
            .then(function(r) { return r.json(); })
            .then(function(d) {
                if (d.success && d.conversation_id) {
                    state.supportLastMsgId = d.message_id || 0;
                    _enterSupportMode(d.conversation_id, d.message_id);
                } else {
                    _addSupportSystemMsg('❌ Could not connect to support. Please try creating a ticket.');
                }
            })
            .catch(function() {
                _addSupportSystemMsg('❌ Network error. Please try again.');
            });
        })
        .catch(function() {
            _addSupportSystemMsg('❌ Could not check admin status. Please try again.');
        });
    }

    function _createTicketFromSupport() {
        var msgs = [];
        document.querySelectorAll('#chat-messages .user-message, #chat-messages .ai-message').forEach(function(el) {
            var role = el.classList.contains('user-message') ? 'You' : 'AI';
            msgs.push(role + ': ' + el.textContent.trim());
        });
        var subject = 'Support request — ' + (document.title || window.location.pathname);
        var description = 'Chat transcript from AI widget:\n\n' + msgs.slice(-10).join('\n\n').slice(0, 1000);
        var params = new URLSearchParams({ subject: subject, description: description, category: 'support', priority: 'normal', from_chat: '1' });
        const ticketUrl = '/HelpDesk/ticket/new?' + params.toString();
        if (window.AI_WIDGET_POPUP && window.opener && !window.opener.closed) {
            window.opener.location.href = ticketUrl;
        } else {
            window.location.href = ticketUrl;
        }
    }

    window.__aiChatSupportFns = {
        ticket:    _createTicketFromSupport,
        startChat: function() {
            var lastUserMsg = '';
            document.querySelectorAll('#chat-messages .user-message').forEach(function(el) { lastUserMsg = el.textContent; });
            _initSupportChat(lastUserMsg.slice(-200) || 'User requested live support');
        },
        exit:      _exitSupportMode
    };

    }

    // Public API used by local-chat.js core (sendMessage flow). Definitions live
    // inside wire(), so expose them on the namespace to stay reachable.
    window.ComservChat.support = {
        wire: wire,
        detectSupportNeeded: function (text) { return _detectSupportNeeded(text); },
        stripSupportTag: function (text) { return _stripSupportTag(text); },
        initSupportChat: function (msg) { _initSupportChat(msg); }
    };
})();
