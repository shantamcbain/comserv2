// ai-chat/index.js — V2 module bootstrap for the AI chat widget.
//
// NOTE: the Voice submodule is wired directly from createChatWidget() in
// local-chat.js (it needs the chat-panel DOM to exist and reaches into the
// chat-core closure for state/sendMessage/audio helpers). It is NOT bootstrapped
// here. Support / page-context modules will be added in later tasks of the
// V2 split and wired the same way (called from local-chat.js after DOM build).
//
// This file currently just asserts the module namespace exists. It is loaded
// last so future ai-chat/*.js modules can rely on window.ComservChat being set.
(function () {
    window.ComservChat = window.ComservChat || {};
})();
