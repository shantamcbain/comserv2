// common/form-filler.js - AI Widget form filling logic
(function() {
    function applyFieldValue(name, value) {
        var el = document.querySelector('[name="' + name + '"]');
        if (!el) return false;

        if (el.tagName === 'SELECT') {
            var v = String(value).toLowerCase();
            for (var i = 0; i < el.options.length; i++) {
                if (el.options[i].value.toLowerCase() === v || el.options[i].text.toLowerCase() === v) {
                    el.selectedIndex = i;
                    el.dispatchEvent(new Event('change', {bubbles:true}));
                    return true;
                }
            }
            return false;
        } else if (el.type === 'radio') {
            var radios = document.querySelectorAll('[name="' + name + '"]');
            var rfound = false;
            radios.forEach(function(r) {
                if (r.value.toLowerCase() === String(value).toLowerCase()) {
                    r.checked = true;
                    r.dispatchEvent(new Event('change', {bubbles:true}));
                    rfound = true;
                } else {
                    r.checked = false;
                }
            });
            return rfound;
        } else if (el.type === 'checkbox') {
            el.checked = !!(value && value !== '0' && value !== 'false');
            el.dispatchEvent(new Event('change', {bubbles:true}));
            return true;
        } else {
            el.value = value;
            el.dispatchEvent(new Event('input', {bubbles:true}));
            el.dispatchEvent(new Event('change', {bubbles:true}));
            return true;
        }
    }

    window.addEventListener('message', function(e) {
        if (!e.data || !e.data.type) return;
        var src = e.source;

        if (e.data.type === 'ai_widget_fields_request') {
            var fields = [];
            document.querySelectorAll(
                'input[name]:not([type=hidden]):not([type=submit]):not([type=button]):not([type=image]),' +
                'textarea[name], select[name]'
            ).forEach(function(el) {
                var label = '';
                if (el.id) {
                    var lbl = document.querySelector('label[for="' + el.id + '"]');
                    if (lbl) label = lbl.textContent.trim().replace(/\s+/g,' ');
                }
                fields.push({
                    name:    el.name,
                    value:   el.tagName === 'SELECT'
                                 ? (el.options[el.selectedIndex] ? el.options[el.selectedIndex].text : '')
                                 : (el.value || ''),
                    label:   label,
                    tagName: el.tagName.toLowerCase(),
                    type:    el.type || ''
                });
            });
            if (src) src.postMessage({
                type:      'ai_widget_fields_response',
                fields:    fields,
                pageTitle: document.title,
                pagePath:  window.location.pathname
            }, '*');
        }

        if (e.data.type === 'ai_widget_fill_one') {
            var ok = applyFieldValue(e.data.field, e.data.value);
            if (src) src.postMessage({ type: 'ai_widget_fill_ack', field: e.data.field, ok: ok }, '*');
        }
    });

    window._applyFieldValue = applyFieldValue;

    // Expose page form fields for the inline widget fill strip
    window._getPageFormFields = function() {
        var skip = '#local-chat-widget, #chat-panel, #chat-button, script, style, nav, footer, header';
        var fields = [];
        document.querySelectorAll(
            'input[name]:not([type=hidden]):not([type=submit]):not([type=button]):not([type=image]):not([type=radio]),' +
            'textarea[name], select[name]'
        ).forEach(function(el) {
            if (el.closest(skip)) return;
            var label = '';
            if (el.id) {
                var lbl = document.querySelector('label[for="' + el.id + '"]');
                if (lbl) label = lbl.textContent.trim().replace(/\s+/g,' ').replace(/\*$/,'').trim();
            }
            fields.push({ name: el.name, label: label || el.name, tagName: el.tagName.toLowerCase(), type: el.type || '' });
        });
        // Add radio groups (one entry per unique name)
        var radioNames = {};
        document.querySelectorAll('input[type=radio][name]').forEach(function(el) {
            if (el.closest(skip)) return;
            if (!radioNames[el.name]) {
                var vals = Array.from(document.querySelectorAll('input[type=radio][name="' + el.name + '"]')).map(function(r){ return r.value; });
                radioNames[el.name] = true;
                fields.push({ name: el.name, label: el.name, tagName: 'input', type: 'radio', options: vals });
            }
        });
        return fields;
    };
})();

console.log('%c[Comserv] form-filler.js loaded', 'color:#0a0');