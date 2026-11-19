/**
 * t/ai2_editor_chat_wiring.test.js
 *
 * Regression test for the AI2 code-editor chat sidebar (todo #2739).
 *
 * Symptom it guards: the editor popup loaded, the user typed a prompt and clicked
 * Send, and NOTHING happened — no POST /ai2/chat reached the server. Cause class:
 * a wiring step (model list / resize / detach / file load) threw BEFORE
 * #ai-chat-send got its click handler, leaving a dead button with no message.
 *
 * Guarantees asserted here:
 *   1. A click handler is attached to #ai-chat-send as soon as the module wires up.
 *   2. It is STILL attached when ComservChat.modelSelect.init throws synchronously.
 *   3. Clicking Send with text in the box actually issues POST /ai2/chat.
 *   4. A failing wiring step is reported in the chat panel and/or status line.
 *
 * Run: node Comserv/t/ai2_editor_chat_wiring.test.js
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const CHAT_JS = process.env.CHAT_JS_FILE
    ? path.resolve(process.env.CHAT_JS_FILE)
    : path.join(__dirname, '..', 'root', 'static', 'js', 'ai2editor', 'chat.js');

let failures = 0;
function ok(cond, msg) {
    if (cond) {
        console.log('ok - ' + msg);
    } else {
        failures += 1;
        console.log('NOT OK - ' + msg);
    }
}

function makeElement(id) {
    const el = {
        id: id,
        tagName: 'DIV',
        style: {},
        dataset: {},
        _listeners: {},
        children: [],
        value: '',
        textContent: '',
        innerHTML: '',
        disabled: false,
        scrollTop: 0,
        scrollHeight: 0,
        offsetWidth: 300,
        options: [],
        selectedIndex: 0,
        addEventListener: function (type, fn) {
            (this._listeners[type] = this._listeners[type] || []).push(fn);
        },
        removeEventListener: function () {},
        appendChild: function (child) { this.children.push(child); return child; },
        insertBefore: function (child) { this.children.push(child); return child; },
        removeChild: function () {},
        remove: function () {},
        setAttribute: function () {},
        getAttribute: function () { return null; },
        querySelector: function () { return null; },
        querySelectorAll: function () { return []; },
        focus: function () {},
        fire: function (type, ev) {
            (this._listeners[type] || []).forEach(function (fn) { fn(ev || {}); });
        },
        hasListener: function (type) {
            return !!(this._listeners[type] && this._listeners[type].length);
        }
    };
    return el;
}

function buildHarness(opts) {
    opts = opts || {};
    const ids = [
        'ai-chat-send', 'ai-chat-input', 'chat-messages', 'ai-chat-sidebar', 'ai-chat-title',
        'ai-chat-resize', 'ai-chat-close', 'ai-chat-reopen', 'ai-chat-detach', 'ai-chat-clear',
        'ai-chat-todo', 'ai-editor-agent', 'ai-editor-phase', 'ai-editor-verify',
        'ai-approve-btn', 'ai-reject-btn', 'model-select', 'file-status'
    ];
    const els = {};
    ids.forEach(function (id) { els[id] = makeElement(id); });

    const domReadyHandlers = [];

    const document = {
        readyState: 'loading',
        hidden: false,
        title: 'AI Code Editor',
        referrer: '',
        body: makeElement('body'),
        head: makeElement('head'),
        documentElement: makeElement('html'),
        getElementById: function (id) { return els[id] || null; },
        createElement: function (tag) { return makeElement('created-' + tag); },
        querySelector: function () { return null; },
        querySelectorAll: function () { return []; },
        addEventListener: function (type, fn) {
            if (type === 'DOMContentLoaded') domReadyHandlers.push(fn);
        },
        removeEventListener: function () {}
    };

    const fetchCalls = [];
    const fetch = function (url, init) {
        fetchCalls.push({ url: String(url), init: init || {} });
        return Promise.resolve({
            ok: true,
            status: 200,
            json: function () { return Promise.resolve({ success: 1, response: 'ok', model: 'test/model' }); }
        });
    };

    const sandbox = {
        document: document,
        fetch: fetch,
        console: console,
        setTimeout: setTimeout,
        clearTimeout: clearTimeout,
        setInterval: function () { return 0; },
        clearInterval: function () {},
        Promise: Promise,
        URLSearchParams: URLSearchParams,
        encodeURIComponent: encodeURIComponent,
        decodeURIComponent: decodeURIComponent,
        localStorage: {
            getItem: function () { return null; },
            setItem: function () {},
            removeItem: function () {}
        },
        location: { search: '?file=root/admin/planning/DailyPlan.tt', pathname: '/ai2/editing_widget_popup', href: 'http://x/ai2/editing_widget_popup' },
        navigator: { userAgent: 'node-test' },
        addEventListener: function () {},
        removeEventListener: function () {},
        open: function () { return null; },
        ComservChat: opts.comservChat || {},
        ComservConfig: {}
    };
    sandbox.window = sandbox;
    sandbox.globalThis = sandbox;

    const context = vm.createContext(sandbox);
    const src = fs.readFileSync(CHAT_JS, 'utf8');
    vm.runInContext(src, context, { filename: CHAT_JS });

    return {
        els: els,
        context: context,
        fetchCalls: fetchCalls,
        fireDomReady: function () { domReadyHandlers.forEach(function (fn) { fn({}); }); },
        panelText: function () {
            return (els['chat-messages'].children || []).map(function (c) {
                return (c.textContent || '') + (c.innerHTML || '');
            }).join('\n');
        }
    };
}

function testSendWiredWithWorkingModelSelect() {
    const h = buildHarness({
        comservChat: {
            modelSelect: {
                init: function () { return Promise.resolve(); },
                getSelectedValue: function () { return 'openrouter|cohere/north-mini-code:free'; }
            }
        }
    });
    h.fireDomReady();
    ok(h.els['ai-chat-send'].hasListener('click'), 'Send click handler attached (normal model list)');
}

function testSendWiredWhenModelSelectThrows() {
    const h = buildHarness({
        comservChat: {
            modelSelect: {
                init: function () { throw new Error('model catalog exploded'); },
                getSelectedValue: function () { return ''; }
            }
        }
    });
    let threw = false;
    try {
        h.fireDomReady();
    } catch (e) {
        threw = true;
    }
    ok(!threw, 'wiring survives a throwing model-select init (no uncaught error)');
    ok(h.els['ai-chat-send'].hasListener('click'),
        'Send click handler STILL attached when the model list blows up');
    ok(/model select/i.test(h.panelText()) || /model select/i.test(h.els['file-status'].textContent),
        'the model-select failure is reported visibly');
}

function testSendIssuesChatPost() {
    const h = buildHarness({
        comservChat: {
            modelSelect: {
                init: function () { return Promise.resolve(); },
                getSelectedValue: function () { return 'openrouter|cohere/north-mini-code:free'; }
            }
        }
    });
    h.fireDomReady();
    // Substantive brief (>=100 chars, no "fix/help/broken", names the file) so the
    // phase-AutoClarify gate does not hold the turn — see testThinAskHeldVisible().
    h.els['ai-chat-input'].value =
        'Review the DailyPlan template pipeline end to end and explain how the stash, the queries '
        + 'and the includes reach root/admin/planning/DailyPlan.tt in this application';
    h.els['ai-chat-send'].fire('click');
    return new Promise(function (resolve) {
        setTimeout(function () {
            const posted = h.fetchCalls.filter(function (c) {
                return c.url.indexOf('/ai2/chat') === 0 && (c.init.method || '').toUpperCase() === 'POST';
            });
            ok(posted.length === 1, 'clicking Send issues exactly one POST /ai2/chat (got ' + posted.length + ')');
            resolve();
        }, 250);
    });
}

// A thin ask is HELD for Clarify on purpose (no model spend). That is allowed —
// but it must be visible, because from the user's seat "Send did nothing".
function testThinAskHeldVisible() {
    const h = buildHarness({
        comservChat: {
            modelSelect: {
                init: function () { return Promise.resolve(); },
                getSelectedValue: function () { return ''; }
            }
        }
    });
    h.fireDomReady();
    h.els['ai-chat-input'].value = 'help';
    h.els['ai-chat-send'].fire('click');
    ok(/clarify/i.test(h.panelText()), 'a held (clarify) send is announced in the chat panel');
    ok(/nothing sent/i.test(h.els['file-status'].textContent),
        'the status line says nothing was sent yet when Clarify holds the turn');
}

async function main() {
    testSendWiredWithWorkingModelSelect();
    testSendWiredWhenModelSelectThrows();
    await testSendIssuesChatPost();
    testThinAskHeldVisible();
    console.log(failures === 0 ? '\nAll AI2 editor chat wiring checks passed' : '\n' + failures + ' check(s) FAILED');
    process.exit(failures === 0 ? 0 : 1);
}

main();
