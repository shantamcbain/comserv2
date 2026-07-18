// ai-chat/wizards.js -- V2 module (extracted from local-chat.js)
// Action wizards: inline form builders for create_yard / create_hive /
// create_queen / create_inspection / create_project. Each renders an inline
// card in the chat window and submits via the chat-core executeAIAction().
//
// This code was a self-contained block inside ComservAIChat's main IIFE. It
// reaches into the closure only for executeAIAction() (injected via .init), so
// it is exposed as ComservChat.wizards and wired from local-chat.js at the
// original block position (run-time, after the module has loaded). Behavior is
// 1:1 with the original code.
(function () {
    window.ComservChat = window.ComservChat || {};

    // Injected dependency -- the chat-core executeAIAction() (closure-private in local-chat.js).
    var executeAIAction = null;

    function init(ctx) {
        executeAIAction = ctx && ctx.executeAIAction;
    }

    function _makeWizardForm(fields, onConfirm) {
        var form = document.createElement('form');
        form.onsubmit = function(e) { e.preventDefault(); onConfirm(form); };
        fields.forEach(function(f) {
            var row = document.createElement('div');
            row.style.cssText = 'margin:4px 0;display:flex;gap:6px;align-items:center;';
            var label = document.createElement('label');
            label.textContent = f.label;
            label.style.cssText = 'width:160px;font-size:12px;color:var(--text-color,#555);flex-shrink:0;';
            var input = document.createElement('input');
            input.name = f.name;
            input.value = f.value !== undefined ? f.value : '';
            input.type = f.type || 'text';
            input.style.cssText = 'flex:1;padding:4px 6px;border:1px solid var(--button-border,#ccc);border-radius:4px;font-size:13px;background:var(--background-color,#fff);color:var(--text-color,#222);';
            if (f.required) input.required = true;
            row.appendChild(label);
            row.appendChild(input);
            form.appendChild(row);
        });
        return form;
    }

    function _postWizardAction(actionName, params, msgEl) {
        msgEl.textContent = '⏳ Saving…';
        fetch('/ai/action', {
            method: 'POST',
            credentials: 'include',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ action: actionName, params: params })
        })
        .then(function(r) { return r.json(); })
        .then(function(result) {
            if (result.success) {
                msgEl.innerHTML = '✅ ' + (result.message || 'Saved') +
                    (result.url ? ' <a href="' + result.url + '" target="_blank" style="color:var(--accent-color, #0077cc);font-weight:bold;">View →</a>' : '');
            } else {
                msgEl.textContent = '⚠️ ' + (result.error || 'Save failed');
            }
        })
        .catch(function(e) { msgEl.textContent = '⚠️ Request failed: ' + e.message; });
    }

    function _openSimpleWizard(title, fields, actionName, extraParams) {
        var chatMessages = document.getElementById('chat-messages');
        if (!chatMessages) return;
        var id = 'ai-' + actionName + '-wizard';
        var existing = document.getElementById(id);
        if (existing) existing.remove();

        var wrapper = document.createElement('div');
        wrapper.id = id;
        wrapper.className = 'msg-wrapper msg-wrapper-ai';
        wrapper.style.cssText = 'margin:8px 0;';

        var card = document.createElement('div');
        card.className = 'message system-message';
        card.style.cssText = 'background:var(--table-header-bg,#f9f9f9);border:1px solid var(--border-color,#ddd);border-radius:8px;padding:12px;max-width:520px;color:var(--text-color,#222);';

        var heading = document.createElement('div');
        heading.textContent = title;
        heading.style.cssText = 'font-weight:bold;font-size:14px;margin-bottom:8px;';
        card.appendChild(heading);

        var msgEl = document.createElement('div');
        msgEl.style.cssText = 'font-size:12px;color:var(--text-muted-color, #666);margin-top:6px;';

        var form = _makeWizardForm(fields, function(f) {
            var params = Object.assign({}, extraParams || {}, { wizard_confirmed: 1 });
            fields.forEach(function(fd) {
                var inp = f.elements[fd.name];
                if (inp) params[fd.name] = inp.value;
            });
            _postWizardAction(actionName, params, msgEl);
        });
        card.appendChild(form);

        var btnRow = document.createElement('div');
        btnRow.style.cssText = 'margin-top:8px;display:flex;gap:8px;';
        var saveBtn = document.createElement('button');
        saveBtn.textContent = 'Save';
        saveBtn.type = 'submit';
        saveBtn.style.cssText = 'background:var(--button-bg,#f2f2f2);color:var(--button-text,#000);border:1px solid var(--button-border,#ccc);border-radius:4px;padding:6px 16px;cursor:pointer;font-size:13px;';
        saveBtn.onclick = function() { form.requestSubmit ? form.requestSubmit() : form.submit(); };
        var cancelBtn = document.createElement('button');
        cancelBtn.textContent = 'Cancel';
        cancelBtn.type = 'button';
        cancelBtn.style.cssText = 'background:var(--button-bg,#f2f2f2);color:var(--button-text,#000);border:1px solid var(--button-border,#ccc);border-radius:4px;padding:6px 12px;cursor:pointer;font-size:13px;';
        cancelBtn.onclick = function() { wrapper.remove(); };
        btnRow.appendChild(saveBtn);
        btnRow.appendChild(cancelBtn);
        card.appendChild(btnRow);
        card.appendChild(msgEl);
        wrapper.appendChild(card);
        chatMessages.appendChild(wrapper);
        chatMessages.scrollTop = chatMessages.scrollHeight;
    }

    function openYardWizard(prefill) {
        _openSimpleWizard('🏡 Create Yard', [
            { name: 'yard_name',       label: 'Yard Name *',      value: prefill.yard_name  || '', required: true },
            { name: 'yard_code',       label: 'Yard Code *',      value: prefill.yard_code  || '', required: true },
            { name: 'yard_size',       label: 'Capacity (hives)', value: prefill.yard_size  || 10, type: 'number' },
            { name: 'total_yard_size', label: 'Total Size (hives)',value: prefill.total_yard_size || 10, type: 'number' },
            { name: 'notes',           label: 'Notes',            value: prefill.notes      || '' },
        ], 'create_yard', {});
    }

    function openHiveWizard(prefill) {
        _openSimpleWizard('🐝 Register Hive', [
            { name: 'hive_number', label: 'Hive Number *', value: prefill.hive_number || '', required: true },
            { name: 'yard_id',     label: 'Yard ID *',     value: prefill.yard_id    || '', required: true, type: 'number' },
            { name: 'queen_code',  label: 'Queen Code',    value: prefill.queen_code || '' },
            { name: 'notes',       label: 'Notes',         value: prefill.notes      || '' },
        ], 'create_hive', {});
    }

    function openQueenWizard(prefill) {
        _openSimpleWizard('👑 Record Queen', [
            { name: 'tag_number',    label: 'Tag / Number',   value: prefill.tag_number    || '' },
            { name: 'color_marking', label: 'Colour Marking', value: prefill.color_marking || '' },
            { name: 'birth_date',    label: 'Birth Date',     value: prefill.birth_date    || '', type: 'date' },
            { name: 'breed',         label: 'Breed',          value: prefill.breed         || 'unknown' },
            { name: 'mating_status', label: 'Mating Status',  value: prefill.mating_status || 'mated' },
            { name: 'health_status', label: 'Health Status',  value: prefill.health_status || 'healthy' },
            { name: 'notes',         label: 'Notes',          value: prefill.notes         || '' },
        ], 'create_queen', { hive_id: prefill.hive_id || undefined });
    }

    // ── openInspectionWizard ───────────────────────────────────────────────────
    // Renders an inline inspection review form pre-filled with AI-extracted data.
    // User can edit all fields before confirming; on confirm sends create_inspection.
    function openInspectionWizard(prefill) {
        var chatMessages = document.getElementById('chat-messages');
        if (!chatMessages) return;

        var existing = document.getElementById('ai-inspection-wizard');
        if (existing) existing.remove();

        var wrapper = document.createElement('div');
        wrapper.className = 'msg-wrapper msg-wrapper-ai';
        wrapper.id = 'ai-inspection-wizard';

        var lbl = document.createElement('div');
        lbl.className = 'msg-label';
        lbl.textContent = 'Hive Inspection Review';

        var box = document.createElement('div');
        box.className = 'message system-message';
        box.style.cssText = 'padding:12px;max-width:520px;font-size:0.88em;';

        var p = prefill || {};
        var qs_yes = p.queen_seen        ? 'checked' : '';
        var qm_yes = p.queen_marked      ? 'checked' : '';
        var eg_yes = p.eggs_seen         ? 'checked' : '';
        var lv_yes = p.larvae_seen       ? 'checked' : '';
        var cb_yes = p.capped_brood_seen ? 'checked' : '';
        var fd_yes = p.feeding_done      ? 'checked' : '';
        var today  = new Date().toISOString().slice(0, 10);

        var popOpts = ['', 'very_strong', 'strong', 'moderate', 'weak', 'very_weak'].map(function(v) {
            var sel = (p.population_estimate || '') === v ? ' selected' : '';
            var lbl2 = v ? v.replace(/_/g, ' ') : '— select —';
            return '<option value="' + v + '"' + sel + '>' + lbl2 + '</option>';
        }).join('');
        var tempOpts = ['calm', 'moderate', 'aggressive', 'very_aggressive'].map(function(v) {
            var sel = (p.temperament || 'calm') === v ? ' selected' : '';
            return '<option value="' + v + '"' + sel + '>' + v.replace(/_/g, ' ') + '</option>';
        }).join('');
        var statusOpts = ['excellent', 'good', 'fair', 'poor', 'critical'].map(function(v) {
            var sel = (p.overall_status || 'good') === v ? ' selected' : '';
            return '<option value="' + v + '"' + sel + '>' + v + '</option>';
        }).join('');

        var inpStyle = 'width:100%;box-sizing:border-box;padding:3px 5px;border:1px solid var(--button-border,#ccc);border-radius:3px;background:var(--background-color,#fff);color:var(--text-color,#222);';
        var selStyle = 'width:100%;padding:3px;border:1px solid var(--button-border,#ccc);border-radius:3px;background:var(--background-color,#fff);color:var(--text-color,#222);';
        var lblStyle = 'font-weight:600;display:block;font-size:0.85em;color:var(--text-color,#333);';

        box.innerHTML =
            '<strong style="font-size:1.05em;color:var(--text-color,#222)">🐝 Review Hive Inspection</strong>' +
            '<p style="margin:4px 0 8px;color:var(--text-color,#555);font-size:0.9em">Review AI-extracted data below, edit any fields, then click Save.</p>' +
            '<form id="ai-insp-form" style="display:flex;flex-direction:column;gap:5px;">' +
                '<div style="display:grid;grid-template-columns:1fr 1fr;gap:5px;">' +
                    '<div><label style="' + lblStyle + '">Hive ID *</label><input name="hive_id" type="number" required value="' + (p.hive_id || '') + '" style="' + inpStyle + '"></div>' +
                    '<div><label style="' + lblStyle + '">Date *</label><input name="inspection_date" type="date" required value="' + (p.inspection_date || today) + '" style="' + inpStyle + '"></div>' +
                    '<div><label style="' + lblStyle + '">Population</label><select name="population_estimate" style="' + selStyle + '">' + popOpts + '</select></div>' +
                    '<div><label style="' + lblStyle + '">Temperament</label><select name="temperament" style="' + selStyle + '">' + tempOpts + '</select></div>' +
                    '<div><label style="' + lblStyle + '">Overall Status</label><select name="overall_status" style="' + selStyle + '">' + statusOpts + '</select></div>' +
                    '<div><label style="' + lblStyle + '">Weather</label><input name="weather_conditions" type="text" value="' + (p.weather_conditions || '') + '" placeholder="sunny, cloudy…" style="' + inpStyle + '"></div>' +
                    '<div><label style="' + lblStyle + '">Temperature (°C)</label><input name="temperature" type="number" step="0.5" value="' + (p.temperature != null ? p.temperature : '') + '" style="' + inpStyle + '"></div>' +
                    '<div><label style="' + lblStyle + '">Inspector</label><input name="inspector" type="text" value="' + (p.inspector || '') + '" style="' + inpStyle + '"></div>' +
                '</div>' +
                '<div style="display:flex;flex-wrap:wrap;gap:8px;margin:4px 0;color:var(--text-color,#333);">' +
                    '<label><input type="checkbox" name="queen_seen" ' + qs_yes + '> Queen seen</label>' +
                    '<label><input type="checkbox" name="queen_marked" ' + qm_yes + '> Queen marked</label>' +
                    '<label><input type="checkbox" name="eggs_seen" ' + eg_yes + '> Eggs</label>' +
                    '<label><input type="checkbox" name="larvae_seen" ' + lv_yes + '> Larvae</label>' +
                    '<label><input type="checkbox" name="capped_brood_seen" ' + cb_yes + '> Capped brood</label>' +
                    '<label><input type="checkbox" name="feeding_done" ' + fd_yes + '> Feeding done</label>' +
                '</div>' +
                '<div style="display:grid;grid-template-columns:1fr 1fr 1fr;gap:5px;">' +
                    '<div><label style="' + lblStyle + '">Swarm cells</label><input name="swarm_cells" type="number" min="0" value="' + (p.swarm_cells || 0) + '" style="' + inpStyle + '"></div>' +
                    '<div><label style="' + lblStyle + '">Queen cells</label><input name="queen_cells" type="number" min="0" value="' + (p.queen_cells || 0) + '" style="' + inpStyle + '"></div>' +
                    '<div><label style="' + lblStyle + '">Supersedure</label><input name="supersedure_cells" type="number" min="0" value="' + (p.supersedure_cells || 0) + '" style="' + inpStyle + '"></div>' +
                '</div>' +
                '<div><label style="' + lblStyle + '">General notes</label><textarea name="general_notes" rows="3" style="' + inpStyle + 'resize:vertical;">' + (p.general_notes || '') + '</textarea></div>' +
                '<div><label style="' + lblStyle + '">Action required</label><textarea name="action_required" rows="2" style="' + inpStyle + 'resize:vertical;">' + (p.action_required || '') + '</textarea></div>' +
                '<div><label style="' + lblStyle + '">Feed type</label><input name="feed_type" type="text" value="' + (p.feed_type || '') + '" placeholder="syrup, fondant…" style="' + inpStyle + '"></div>' +
                '<div><label style="' + lblStyle + '">Feed amount</label><input name="feed_amount" type="text" value="' + (p.feed_amount || '') + '" placeholder="1L, 500g…" style="' + inpStyle + '"></div>' +
                '<div id="ai-insp-status" style="display:none;font-style:italic;font-size:0.85em;color:var(--text-color,#555);"></div>' +
                '<div style="display:flex;gap:8px;margin-top:4px;">' +
                    '<button type="submit" style="padding:5px 14px;background:var(--button-bg,#0077cc);color:var(--button-text,#000);border:1px solid var(--button-border,#ccc);border-radius:4px;cursor:pointer;font-size:.88em">Save Inspection</button>' +
                    '<button type="button" id="ai-insp-cancel" style="padding:5px 10px;border:1px solid var(--button-border,#ccc);border-radius:4px;cursor:pointer;font-size:.88em;background:var(--button-bg,#f2f2f2);color:var(--button-text,#000)">Cancel</button>' +
                '</div>' +
            '</form>';

        wrapper.appendChild(lbl);
        wrapper.appendChild(box);
        chatMessages.appendChild(wrapper);
        chatMessages.scrollTop = chatMessages.scrollHeight;

        document.getElementById('ai-insp-cancel').addEventListener('click', function() {
            wrapper.remove();
        });

        document.getElementById('ai-insp-form').addEventListener('submit', function(e) {
            e.preventDefault();
            var fd = new FormData(e.target);
            var confirmed = { box_details: p.box_details || [] };
            fd.forEach(function(val, key) { confirmed[key] = val; });
            confirmed.queen_seen        = e.target.queen_seen.checked        ? 1 : 0;
            confirmed.queen_marked      = e.target.queen_marked.checked      ? 1 : 0;
            confirmed.eggs_seen         = e.target.eggs_seen.checked         ? 1 : 0;
            confirmed.larvae_seen       = e.target.larvae_seen.checked       ? 1 : 0;
            confirmed.capped_brood_seen = e.target.capped_brood_seen.checked ? 1 : 0;
            confirmed.feeding_done      = e.target.feeding_done.checked      ? 1 : 0;
            confirmed.swarm_cells       = parseInt(confirmed.swarm_cells, 10) || 0;
            confirmed.queen_cells       = parseInt(confirmed.queen_cells, 10) || 0;
            confirmed.supersedure_cells = parseInt(confirmed.supersedure_cells, 10) || 0;

            var statusDiv = document.getElementById('ai-insp-status');
            if (statusDiv) { statusDiv.textContent = 'Saving…'; statusDiv.style.display = ''; }
            e.target.querySelector('[type=submit]').disabled = true;

            executeAIAction({ action: 'create_inspection', params: confirmed });

            setTimeout(function() { wrapper.remove(); }, 1500);
        });
    }

    // Project creation wizard — renders an inline form in the chat window.
    // Submitted data is sent to /ai/action as a create_project ACTION.
    function openProjectWizard(prefillTitle) {
        const chatMessages = document.getElementById('chat-messages');
        if (!chatMessages) return;

        const existing = document.getElementById('ai-project-wizard');
        if (existing) existing.remove();

        const wrapper = document.createElement('div');
        wrapper.className = 'msg-wrapper msg-wrapper-ai';
        wrapper.id = 'ai-project-wizard';

        const lbl = document.createElement('div');
        lbl.className = 'msg-label';
        lbl.textContent = 'Planning Agent';

        const box = document.createElement('div');
        box.className = 'message system-message';
        box.style.cssText = 'padding:12px;max-width:480px;';

        const DEPS = [
            ['inventory',   'Inventory tracking'],
            ['billing',     'Billing / payments'],
            ['email',       'Email notifications'],
            ['calendar',    'Calendar / bookings'],
            ['helpdesk',    'HelpDesk / support'],
            ['api',         'External API'],
            ['schema',      'New DB tables needed'],
            ['ai',          'AI / Chat integration'],
        ];

        box.innerHTML =
            '<strong style="font-size:1.05em">📋 New Project Wizard</strong>' +
            '<form id="ai-wizard-form" style="margin-top:8px;display:flex;flex-direction:column;gap:6px;">' +
                '<label style="font-size:.85em;font-weight:600">Project name</label>' +
                '<input id="wiz-name" type="text" required style="padding:4px 6px;border:1px solid var(--border-color, #ccc);border-radius:4px;" value="' + (prefillTitle || '').replace(/"/g, '&quot;') + '">' +
                '<label style="font-size:.85em;font-weight:600">Description</label>' +
                '<textarea id="wiz-desc" rows="2" style="padding:4px 6px;border:1px solid var(--border-color, #ccc);border-radius:4px;resize:vertical;"></textarea>' +
                '<label style="font-size:.85em;font-weight:600">Due date</label>' +
                '<input id="wiz-due" type="date" style="padding:4px 6px;border:1px solid var(--border-color, #ccc);border-radius:4px;">' +
                '<label style="font-size:.85em;font-weight:600">Dependencies needed (check all that apply)</label>' +
                '<div id="wiz-deps" style="display:flex;flex-wrap:wrap;gap:4px 12px;">' +
                    DEPS.map(function(d) {
                        return '<label style="font-size:.82em"><input type="checkbox" name="dep" value="' + d[0] + '" style="margin-right:3px">' + d[1] + '</label>';
                    }).join('') +
                '</div>' +
                '<div style="display:flex;gap:8px;margin-top:4px;">' +
                    '<button type="submit" style="padding:5px 14px;background:var(--button-bg,#f2f2f2);color:var(--button-text,#000);border:1px solid var(--button-border,#ccc);border-radius:4px;cursor:pointer;font-size:.85em">Create Project</button>' +
                    '<button type="button" id="wiz-cancel" style="padding:5px 10px;border:1px solid var(--button-border,#ccc);border-radius:4px;cursor:pointer;font-size:.85em;background:var(--button-bg,#f2f2f2);color:var(--button-text,#000)">Cancel</button>' +
                '</div>' +
            '</form>';

        wrapper.appendChild(lbl);
        wrapper.appendChild(box);
        chatMessages.appendChild(wrapper);
        chatMessages.scrollTop = chatMessages.scrollHeight;

        document.getElementById('wiz-cancel').addEventListener('click', function() {
            wrapper.remove();
        });

        document.getElementById('ai-wizard-form').addEventListener('submit', function(e) {
            e.preventDefault();
            var name = document.getElementById('wiz-name').value.trim();
            var desc = document.getElementById('wiz-desc').value.trim();
            var due  = document.getElementById('wiz-due').value;
            var deps = Array.from(document.querySelectorAll('#wiz-deps input:checked')).map(function(cb) { return cb.value; });

            if (!name) { alert('Project name is required.'); return; }

            var depNote = deps.length ? '\n\nDependencies: ' + deps.join(', ') : '';
            wrapper.remove();

            executeAIAction({
                action: 'create_project',
                params: {
                    name:        name,
                    description: desc + depNote,
                    due_date:    due || undefined,
                }
            });

            if (deps.length) {
                var depMsg = 'Project "' + name + '" was created. Dependencies noted: ' + deps.join(', ') + '. Please create the relevant sub-project todos and blocking dependencies.';
                var chatInput = document.getElementById('chat-input') || document.getElementById('chat-message');
                if (chatInput) {
                    chatInput.value = depMsg;
                    var sendBtn = document.getElementById('send-button') || document.querySelector('[data-action="send"]');
                    if (sendBtn) sendBtn.click();
                }
            }
        });
    }

    // Public API -- called from local-chat.js executeAIAction() .then() handlers.
    window.ComservChat.wizards = {
        init:                 init,
        openProjectWizard:    openProjectWizard,
        openInspectionWizard: openInspectionWizard,
        openYardWizard:       openYardWizard,
        openHiveWizard:       openHiveWizard,
        openQueenWizard:      openQueenWizard
    };
})();
