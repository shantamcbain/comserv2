/* apiary/voice.js — Beekeeper voice inspection recording (v2, 2026-07-25)
 *
 * Wires the #apiary-voice panel (in Apiary/hive_management.tt) to the v2
 * transcription pipeline:
 *   1. Record via MediaRecorder OR upload a saved audio file.
 *   2. POST the blob to /ai2/transcribe  (field name: audio) carrying
 *      hive_id / inspection_id form fields so the server can persist the
 *      transcript to voice_transcripts + draft an inspection row.
 *   3. Poll /ai2/transcribe_status?job_id= until done.
 *   4. Render the transcript + parsed observation fields into the form,
 *      let the user edit, then POST the draft to /ai2/apiary_voice_save.
 *
 * Theme-compliant: uses CSS custom properties via the .apiary-voice classes
 * defined in the template <style> block.
 */
(function () {
    'use strict';

    function $(id) { return document.getElementById(id); }

    function setStatus(el, msg, isError) {
        if (!el) return;
        el.textContent = msg || '';
        el.style.color = isError ? 'var(--danger-color,#dc2626)' : 'var(--text-muted,#666)';
    }

    function loadHives(root, yardInput, hiveSelect) {
        var url = root.dataset.hives || '/ai2/apiary_voice_hives';
        var yard = (yardInput.value || '').trim();
        var sep = url.indexOf('?') === -1 ? '?' : '&';
        var req = new XMLHttpRequest();
        req.open('GET', url + sep + 'yard_id=' + encodeURIComponent(yard), true);
        req.onload = function () {
            if (req.status !== 200) return;
            try {
                var data = JSON.parse(req.responseText);
                var hives = (data && data.hives) || [];
                var prev = hiveSelect.value;
                hiveSelect.innerHTML = '<option value="">— select hive —</option>';
                hives.forEach(function (h) {
                    var opt = document.createElement('option');
                    opt.value = h.id;
                    opt.textContent = h.label || ('Hive #' + h.id);
                    hiveSelect.appendChild(opt);
                });
                if (prev) hiveSelect.value = prev;
            } catch (e) { /* ignore */ }
        };
        req.send();
    }

    function pollStatus(root, jobId, statusEl, onDone) {
        var url = (root.dataset.status || '/ai2/transcribe_status') + '?job_id=' + encodeURIComponent(jobId);
        var attempts = 0;
        var timer = setInterval(function () {
            attempts++;
            var req = new XMLHttpRequest();
            req.open('GET', url, true);
            req.onload = function () {
                var data;
                try { data = JSON.parse(req.responseText); } catch (e) { data = {}; }
                if (data.status === 'processing' || data.success === true && !data.transcript) {
                    if (attempts > 120) { // ~2 min cap
                        clearInterval(timer);
                        setStatus(statusEl, 'Transcription timed out. Try again.', true);
                    }
                    return;
                }
                clearInterval(timer);
                if (data.success && data.transcript) {
                    onDone(data);
                } else {
                    setStatus(statusEl, 'Transcription failed: ' + (data.error || 'unknown error'), true);
                }
            };
            req.onerror = function () {
                clearInterval(timer);
                setStatus(statusEl, 'Network error during transcription.', true);
            };
            req.send();
        }, 1500);
    }

    function submitAudio(root, blob, statusEl) {
        var fd = new FormData();
        fd.append('audio', blob, 'inspection.' + (blob.type.indexOf('webm') !== -1 ? 'webm' : 'wav'));
        var hiveId = $('av-hive') ? $('av-hive').value : '';
        if (hiveId) fd.append('hive_id', hiveId);
        // inspection_id is only known after a draft exists; left blank here.

        var req = new XMLHttpRequest();
        req.open('POST', root.dataset.transcribe || '/ai2/transcribe', true);
        req.onload = function () {
            var data;
            try { data = JSON.parse(req.responseText); } catch (e) { data = {}; }
            if (data.success && data.job_id) {
                setStatus(statusEl, 'Transcribing…');
                pollStatus(root, data.job_id, statusEl, function (res) { renderResult(root, res, statusEl); });
            } else {
                setStatus(statusEl, 'Upload failed: ' + (data.error || 'unknown'), true);
            }
        };
        req.onerror = function () { setStatus(statusEl, 'Upload network error.', true); };
        req.send(fd);
    }

    function renderResult(root, data, statusEl) {
        $('av-transcript').value = data.transcript || '';
        $('av-transcript-wrap').hidden = false;
        setStatus(statusEl, 'Transcription complete.');

        // Pre-fill parsed observation fields (best-effort from transcript).
        var seg = (data.transcript || '').toLowerCase();
        function on(re) { return re.test(seg); }
        $('av-queen_seen').checked       = on(/\b(saw|see|found|spotted)\b.*\bqueen\b/);
        $('av-queen_marked').checked     = on(/\bqueen\b.*\bmarked\b/);
        $('av-eggs_seen').checked        = on(/\beggs?\b/);
        $('av-larvae_seen').checked      = on(/\blarv(ae?|e)\b/);
        $('av-capped_brood_seen').checked= on(/\bcapped\b.*\bbrood\b/);
        $('av-feeding_done').checked     = on(/\b(fed|feeding|syrup|fondant)\b/);

        var pop = seg.match(/\b(very strong|strong|moderate|weak|very weak)\b/);
        $('av-population_estimate').value = pop ? pop[1].replace(' ', '_') : '';
        var tem = seg.match(/\b(aggressive|calm|gentle|moderate)\b/);
        $('av-temperament').value = tem ? (tem[1] === 'gentle' ? 'calm' : tem[1]) : '';
        var st  = seg.match(/\b(excellent|good|fair|poor|critical)\b/);
        $('av-overall_status').value = st ? st[1] : '';

        var sw = seg.match(/(\d+)\s*swarm\s*cells?/);    if (sw) $('av-swarm_cells').value = sw[1];
        var qc = seg.match(/(\d+)\s*queen\s*cells?/);    if (qc) $('av-queen_cells').value = qc[1];
        var su = seg.match(/(\d+)\s*supersedure/);       if (su) $('av-supersedure_cells').value = su[1];

        $('av-general_notes').value = data.transcript || '';

        // Stash ids for save.
        root.dataset.voiceTranscriptId = data.voice_transcript_id || '';
        root.dataset.inspectionId      = data.inspection_id || '';
        $('av-save').disabled = !$('av-hive').value;
        if (!$('av-hive').value) {
            setStatus(statusEl, 'Transcription complete — select a hive to save the draft.', false);
        }
    }

    function saveDraft(root, statusEl) {
        var hiveId = $('av-hive').value;
        var inspId = root.dataset.inspectionId || '';
        if (!hiveId && !inspId) { setStatus(statusEl, 'Select a hive first.', true); return; }

        var fd = new FormData();
        if (inspId) fd.append('inspection_id', inspId);
        function bool(id) { var e = $(id); return e && e.checked ? '1' : '0'; }
        function val(id) { var e = $(id); return e ? e.value : ''; }
        ['queen_seen','queen_marked','eggs_seen','larvae_seen','capped_brood_seen','feeding_done']
            .forEach(function (k) { fd.append(k, bool('av-' + k)); });
        ['population_estimate','temperament','overall_status','general_notes'].forEach(function (k) {
            var v = val('av-' + k); if (v) fd.append(k, v);
        });
        ['swarm_cells','queen_cells','supersedure_cells'].forEach(function (k) {
            var v = val('av-' + k); if (v !== '' && v != null) fd.append(k, v);
        });

        var req = new XMLHttpRequest();
        req.open('POST', root.dataset.save || '/ai2/apiary_voice_save', true);
        req.onload = function () {
            var data; try { data = JSON.parse(req.responseText); } catch (e) { data = {}; }
            if (data.success) {
                root.dataset.inspectionId = data.inspection_id || root.dataset.inspectionId;
                setStatus(statusEl, 'Draft saved (inspection #' + (data.inspection_id || root.dataset.inspectionId) + ').');
                $('av-save').disabled = true;
            } else {
                setStatus(statusEl, 'Save failed: ' + (data.error || 'unknown'), true);
            }
        };
        req.onerror = function () { setStatus(statusEl, 'Save network error.', true); };
        req.send(fd);
    }

    function wire(root) {
        if (!root) return;
        var micBtn   = $('av-mic');
        var fileInput= $('av-file');
        var yardInput= $('av-yard');
        var hiveSel  = $('av-hive');
        var statusEl = $('av-status');
        var saveBtn  = $('av-save');

        var mediaRecorder = null;
        var chunks = [];

        loadHives(root, yardInput, hiveSel);
        if (yardInput) {
            yardInput.addEventListener('change', function () { loadHives(root, yardInput, hiveSel); });
        }
        if (hiveSel) {
            hiveSel.addEventListener('change', function () {
                if ($('av-transcript-wrap') && !$('av-transcript-wrap').hidden) {
                    saveBtn.disabled = !hiveSel.value;
                }
            });
        }

        if (micBtn) {
            micBtn.addEventListener('click', function () {
                if (mediaRecorder && mediaRecorder.state === 'recording') {
                    mediaRecorder.stop();
                    return;
                }
                if (!navigator.mediaDevices || !window.MediaRecorder) {
                    var msg = location.protocol === 'https:'
                        ? 'Microphone recording not available in this browser. Use 📂 to upload.'
                        : 'Microphone requires HTTPS. Use 📂 to upload a saved file.';
                    setStatus(statusEl, msg, true);
                    return;
                }
                navigator.mediaDevices.getUserMedia({ audio: true }).then(function (stream) {
                    var mime = MediaRecorder.isTypeSupported('audio/webm;codecs=opus') ? 'audio/webm;codecs=opus'
                             : MediaRecorder.isTypeSupported('audio/ogg;codecs=opus')  ? 'audio/ogg;codecs=opus'
                             : 'audio/webm';
                    mediaRecorder = new MediaRecorder(stream, { mimeType: mime });
                    chunks = [];
                    mediaRecorder.ondataavailable = function (e) { if (e.data.size) chunks.push(e.data); };
                    mediaRecorder.onstop = function () {
                        stream.getTracks().forEach(function (t) { t.stop(); });
                        micBtn.classList.remove('recording');
                        micBtn.textContent = '🎤 Record';
                        var blob = new Blob(chunks, { type: mediaRecorder.mimeType || 'audio/webm' });
                        setStatus(statusEl, 'Uploading…');
                        submitAudio(root, blob, statusEl);
                    };
                    mediaRecorder.start();
                    micBtn.classList.add('recording');
                    micBtn.textContent = '⏹ Stop';
                    setStatus(statusEl, 'Recording… click Stop when done.');
                }).catch(function () {
                    setStatus(statusEl, 'Microphone permission denied. Use 📂 to upload.', true);
                });
            });
        }

        if (fileInput) {
            fileInput.addEventListener('change', function () {
                var f = fileInput.files && fileInput.files[0];
                if (!f) return;
                setStatus(statusEl, 'Uploading…');
                submitAudio(root, f, statusEl);
                fileInput.value = '';
            });
        }

        if (saveBtn) {
            saveBtn.addEventListener('click', function () { saveDraft(root, statusEl); });
        }
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', function () { wire($('apiary-voice')); });
    } else {
        wire($('apiary-voice'));
    }
})();
