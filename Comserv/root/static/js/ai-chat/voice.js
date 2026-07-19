// ai-chat/voice.js — V2 module (extracted from local-chat.js)
// Voice / SpeechRec: mic recorder + voice conversation mode (VAD + Web Speech + TTS).
// Exposes window.ComservChat.voice.wire(ctx) where ctx carries the chat-core
// closure dependencies (state, sendMessage, and the audio backup/transcribe helpers)
// because this code runs inside ComservAIChat's main IIFE closure.
// Wired from createChatWidget() AFTER the chat panel DOM is built, so the
// mic-record-btn / voice-mode-btn elements exist. Behavior is 1:1 with the
// original inline IIFEs.
(function () {
    window.ComservChat = window.ComservChat || {};

    function wire(ctx) {
        // Bind closure-private dependencies passed in by local-chat.js core.
        var state                    = ctx.state;
        var sendMessage              = ctx.sendMessage;
        var _saveAudioBackup         = ctx.saveAudioBackup;
        var _transcribeAudioFile     = ctx.transcribeAudioFile;
        var _renderLocalAudioBackups = ctx.renderLocalAudioBackups;

        (function _initMicRecorder() {
            var micBtn = document.getElementById('mic-record-btn');
            if (!micBtn) return;
            if (!window.MediaRecorder || !navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
                micBtn.addEventListener('click', function() {
                    var _statusEl = document.getElementById('audio-transcribe-status');
                    var msg = window.isSecureContext === false
                        ? '⚠️ Microphone requires HTTPS. Use the 📂 button to upload a saved audio file instead.'
                        : '⚠️ Microphone recording is not available in this browser. Use the 📂 button to upload a saved audio file instead.';
                    if (_statusEl) { _statusEl.textContent = msg; _statusEl.style.display = ''; }
                });
                return;
            }

            var _mediaRec   = null;
            var _chunks     = [];
            var _stream     = null;
            var _recTimer   = null;
            var _recStart   = null;
            var _wakeLock   = null;

            function _requestWakeLock() {
                if (navigator.wakeLock && typeof navigator.wakeLock.request === 'function') {
                    navigator.wakeLock.request('screen').then(function(lock) {
                        _wakeLock = lock;
                    }).catch(function(err) {
                        console.warn('Screen Wake Lock request failed:', err);
                    });
                }
            }

            function _releaseWakeLock() {
                if (_wakeLock) {
                    _wakeLock.release().then(function() {
                        _wakeLock = null;
                    }).catch(function(err) {
                        console.warn('Screen Wake Lock release failed:', err);
                    });
                }
            }

            document.addEventListener('visibilitychange', function() {
                if (_mediaRec && _mediaRec.state === 'recording' && document.visibilityState === 'visible') {
                    _requestWakeLock();
                }
            });

            function _fmtElapsed(ms) {
                var s = Math.floor(ms / 1000);
                var m = Math.floor(s / 60);
                s = s % 60;
                return m + ':' + (s < 10 ? '0' : '') + s;
            }

            micBtn.addEventListener('click', function() {
                if (_mediaRec && _mediaRec.state === 'recording') {
                    _mediaRec.stop();
                    _releaseWakeLock();
                    clearInterval(_recTimer);
                    _recTimer = null;
                    return;
                }
                navigator.mediaDevices.getUserMedia({ audio: true }).then(function(stream) {
                    _stream  = stream;
                    _chunks  = [];
                    var mimeType = MediaRecorder.isTypeSupported('audio/webm;codecs=opus') ? 'audio/webm;codecs=opus'
                                 : MediaRecorder.isTypeSupported('audio/ogg;codecs=opus')  ? 'audio/ogg;codecs=opus'
                                 : 'audio/webm';
                    _mediaRec = new MediaRecorder(stream, { mimeType: mimeType });

                    _mediaRec.ondataavailable = function(ev) {
                        if (ev.data && ev.data.size > 0) _chunks.push(ev.data);
                    };

                    _mediaRec.onstop = function() {
                        clearInterval(_recTimer);
                        _recTimer = null;
                        _releaseWakeLock();
                        stream.getTracks().forEach(function(t) { t.stop(); });
                        var blob = new Blob(_chunks, { type: _mediaRec.mimeType || 'audio/webm' });
                        var ext  = ((_mediaRec.mimeType || '').indexOf('ogg') !== -1) ? 'ogg' : 'webm';
                        var elapsed = _recStart ? _fmtElapsed(Date.now() - _recStart) : '';
                        var file = new File([blob], 'recording.' + ext, { type: blob.type });

                        var backupId = 'rec_' + Date.now() + '_' + Math.random().toString(36).substring(2, 7);
                        _saveAudioBackup(backupId, file, elapsed).then(function() {
                            _transcribeAudioFile(file, backupId);
                            _renderLocalAudioBackups();
                        }).catch(function(err) {
                            console.error('Failed to save audio backup:', err);
                            _transcribeAudioFile(file);
                        });

                        micBtn.textContent = '🎤';
                        micBtn.title = 'Record voice inspection — click to start, click again to stop. No time limit.';
                        micBtn.style.background = '';
                        var _statusEl = document.getElementById('audio-transcribe-status');
                        if (_statusEl) { _statusEl.textContent = '⏳ Recording stopped (' + elapsed + ') — uploading…'; }
                    };

                    _mediaRec.start(1000);
                    _requestWakeLock();
                    _recStart = Date.now();
                    micBtn.textContent = '⏹';
                    micBtn.title = 'Stop recording';
                    micBtn.style.background = 'var(--recording-bg, #ffd0d0)';

                    var _statusEl = document.getElementById('audio-transcribe-status');
                    if (_statusEl) { _statusEl.textContent = '🔴 Recording 0:00 — click ⏹ to stop (no time limit)'; _statusEl.style.display = ''; }

                    _recTimer = setInterval(function() {
                        var el = document.getElementById('audio-transcribe-status');
                        if (el && _recStart) {
                            el.textContent = '🔴 Recording ' + _fmtElapsed(Date.now() - _recStart) + ' — click ⏹ to stop (no time limit)';
                        }
                    }, 1000);
                }).catch(function(err) {
                    var _statusEl = document.getElementById('audio-transcribe-status');
                    if (_statusEl) { _statusEl.textContent = '⚠️ Microphone access denied: ' + err.message; _statusEl.style.display = ''; }
                });
            });
        })();

        // ── Voice Conversation Mode ────────────────────────────────────────────
        // Full hands-free loop: user speaks → auto-sent to AI → AI response read aloud
        // → listening restarts.
        //
        // STT strategy (in priority order):
        //   1. Web Speech API  — Chrome/Edge/Safari (streaming, instant)
        //   2. VAD + Whisper   — Firefox and any browser without SpeechRecognition
        //                        Uses AudioContext to detect speech, records via
        //                        MediaRecorder, uploads to /ai/transcribe (our server).
        //                        No audio leaves to third-party servers. 1-3s delay.
        // TTS: speechSynthesis — all browsers.
        (function() {
            var _SpeechRec = window.SpeechRecognition || window.webkitSpeechRecognition;
            var _hasTTS    = !!(window.speechSynthesis);
            var _hasVAD    = !!(window.AudioContext || window.webkitAudioContext) && !!(window.MediaRecorder) && !!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia);
            var _voiceBtn  = document.getElementById('voice-mode-btn');
            if (!_voiceBtn) return;

            if (_hasTTS || _SpeechRec || _hasVAD) { _voiceBtn.style.display = ''; }

            var _voiceActive = false;
            var _recog       = null;
            var _ttsSpeaking = false;
            var _voiceStatus = document.getElementById('audio-transcribe-status');

            var _vadStream   = null;
            var _vadCtx      = null;
            var _vadRec      = null;
            var _vadChunks   = [];
            var _vadSpeaking = false;
            var _vadSilTimer = null;
            var _vadRafId    = null;

            var VAD_SPEAK_THRESH  = 18;
            var VAD_SILENCE_MS    = 1400;
            var VAD_MIN_SPEECH_MS = 300;
            var _vadSpeakStart    = 0;

            function _setVoiceStatus(msg) {
                if (_voiceStatus) { _voiceStatus.textContent = msg; _voiceStatus.style.display = msg ? '' : 'none'; }
            }

            function _speak(text) {
                if (!_hasTTS || !_voiceActive) return;
                window.speechSynthesis.cancel();
                var clean = text
                    .replace(/\[ACTION:[^\]]*\]/gi, '')
                    .replace(/#{1,6}\s*/g, '')
                    .replace(/\*\*([^*]+)\*\*/g, '$1')
                    .replace(/\*([^*]+)\*/g, '$1')
                    .replace(/`[^`]+`/g, function(m){ return m.replace(/`/g,''); })
                    .replace(/https?:\/\/\S+/g, '')
                    .trim();
                if (!clean) { _startListening(); return; }
                _ttsSpeaking = true;
                _setVoiceStatus('🔈 Speaking…');
                var utter = new window.SpeechSynthesisUtterance(clean);
                utter.lang  = 'en-US';
                utter.rate  = 1.05;
                utter.pitch = 1.0;
                utter.onend  = function() { _ttsSpeaking = false; if (_voiceActive) { _setVoiceStatus(''); _startListening(); } };
                utter.onerror = function() { _ttsSpeaking = false; if (_voiceActive) { _setVoiceStatus(''); _startListening(); } };
                window.speechSynthesis.speak(utter);
            }

            state._speakResponse = _speak;

            function _stopVAD() {
                if (_vadRafId) { cancelAnimationFrame(_vadRafId); _vadRafId = null; }
                if (_vadSilTimer) { clearTimeout(_vadSilTimer); _vadSilTimer = null; }
                if (_vadRec && _vadRec.state !== 'inactive') { try { _vadRec.stop(); } catch(e){} }
                if (_vadStream) { _vadStream.getTracks().forEach(function(t){ t.stop(); }); _vadStream = null; }
                if (_vadCtx) { try { _vadCtx.close(); } catch(e){} _vadCtx = null; }
                _vadRec = null; _vadChunks = []; _vadSpeaking = false;
            }

            function _uploadVADBlob(blob) {
                if (!blob || blob.size < 1000) { _startListening(); return; }
                _setVoiceStatus('⏳ Transcribing speech…');
                var ext = (blob.type.indexOf('ogg') !== -1) ? 'ogg' : 'webm';
                var file = new File([blob], 'voice.' + ext, { type: blob.type });
                var fd = new FormData();
                fd.append('audio', file, file.name);
                fd.append('diarize', '0');
                fetch('/ai/transcribe', { method: 'POST', credentials: 'include', body: fd })
                .then(function(r){ return r.json(); })
                .then(function(data) {
                    if (!_voiceActive) return;
                    var txt = (data.transcript || '').trim();
                    if (!txt) { _setVoiceStatus('👂 Nothing heard — listening…'); _startListening(); return; }
                    var inputEl = document.getElementById('message-input');
                    if (inputEl) inputEl.value = txt;
                    _setVoiceStatus('📤 Sending: "' + txt.substring(0, 50) + (txt.length > 50 ? '…' : '') + '"');
                    sendMessage();
                })
                .catch(function() {
                    if (_voiceActive) { _setVoiceStatus('⚠️ Transcription failed — retrying…'); setTimeout(_startListening, 1500); }
                });
            }

            function _startVAD() {
                if (!_voiceActive) return;
                _setVoiceStatus('👂 Listening… (speak now)');
                navigator.mediaDevices.getUserMedia({ audio: true }).then(function(stream) {
                    if (!_voiceActive) { stream.getTracks().forEach(function(t){ t.stop(); }); return; }
                    _vadStream  = stream;
                    _vadChunks  = [];
                    _vadSpeaking = false;
                    var ACtx = window.AudioContext || window.webkitAudioContext;
                    _vadCtx = new ACtx();
                    var source   = _vadCtx.createMediaStreamSource(stream);
                    var analyser = _vadCtx.createAnalyser();
                    analyser.fftSize = 512;
                    source.connect(analyser);
                    var buf = new Uint8Array(analyser.fftSize);
                    var mimeType = MediaRecorder.isTypeSupported('audio/webm;codecs=opus') ? 'audio/webm;codecs=opus'
                                 : MediaRecorder.isTypeSupported('audio/ogg;codecs=opus')  ? 'audio/ogg;codecs=opus'
                                 : 'audio/webm';
                    _vadRec = new MediaRecorder(stream, { mimeType: mimeType });
                    _vadRec.ondataavailable = function(ev) { if (ev.data && ev.data.size > 0) _vadChunks.push(ev.data); };
                    _vadRec.onstop = function() {
                        var blob = new Blob(_vadChunks, { type: _vadRec.mimeType || 'audio/webm' });
                        _vadChunks = [];
                        _uploadVADBlob(blob);
                    };
                    function _tick() {
                        if (!_voiceActive) { _stopVAD(); return; }
                        analyser.getByteTimeDomainData(buf);
                        var rms = 0;
                        for (var i = 0; i < buf.length; i++) { var d = (buf[i] - 128); rms += d * d; }
                        rms = Math.sqrt(rms / buf.length);
                        if (rms > VAD_SPEAK_THRESH) {
                            if (!_vadSpeaking) {
                                _vadSpeaking = true;
                                _vadSpeakStart = Date.now();
                                _vadChunks = [];
                                _vadRec.start(100);
                                _setVoiceStatus('🔴 Recording…');
                            }
                            if (_vadSilTimer) { clearTimeout(_vadSilTimer); _vadSilTimer = null; }
                        } else if (_vadSpeaking) {
                            if (!_vadSilTimer) {
                                _vadSilTimer = setTimeout(function() {
                                    _vadSilTimer = null;
                                    if (!_vadSpeaking) return;
                                    _vadSpeaking = false;
                                    var dur = Date.now() - _vadSpeakStart;
                                    if (dur < VAD_MIN_SPEECH_MS) {
                                        _vadRec.stop();
                                        _vadChunks = [];
                                        _setVoiceStatus('👂 Listening… (speak now)');
                                        _vadRec = new MediaRecorder(stream, { mimeType: mimeType });
                                        _vadRec.ondataavailable = function(ev){ if (ev.data && ev.data.size > 0) _vadChunks.push(ev.data); };
                                        _vadRec.onstop = function(){ var blob = new Blob(_vadChunks, { type: _vadRec.mimeType || 'audio/webm' }); _vadChunks = []; _uploadVADBlob(blob); };
                                    } else {
                                        _vadRec.stop();
                                    }
                                }, VAD_SILENCE_MS);
                            }
                        }
                        _vadRafId = requestAnimationFrame(_tick);
                    }
                    _vadRafId = requestAnimationFrame(_tick);
                }).catch(function(err) {
                    _setVoiceStatus('⚠️ Microphone access denied: ' + err.message);
                });
            }

            function _startSpeechRec() {
                if (!_voiceActive) return;
                if (_recog) { try { _recog.abort(); } catch(e){} }
                _recog = new _SpeechRec();
                _recog.lang = 'en-US';
                _recog.continuous = false;
                _recog.interimResults = true;
                _recog.maxAlternatives = 1;
                var _inputEl = document.getElementById('message-input');
                _setVoiceStatus('👂 Listening… (speak now)');
                _recog.onresult = function(ev) {
                    var interim = '', fin = '';
                    for (var i = ev.resultIndex; i < ev.results.length; i++) {
                        var t = ev.results[i][0].transcript;
                        if (ev.results[i].isFinal) { fin += t; } else { interim += t; }
                    }
                    if (_inputEl) _inputEl.value = fin || interim;
                };
                _recog.onend = function() {
                    var txt = _inputEl ? (_inputEl.value || '').trim() : '';
                    if (txt && _voiceActive) {
                        _setVoiceStatus('📤 Sending: "' + txt.substring(0, 50) + (txt.length > 50 ? '…' : '') + '"');
                        sendMessage();
                    } else if (_voiceActive) {
                        _setVoiceStatus('👂 Listening… (nothing heard, trying again)');
                        setTimeout(_startSpeechRec, 800);
                    }
                };
                _recog.onerror = function(ev) {
                    if (ev.error === 'no-speech' && _voiceActive) { setTimeout(_startSpeechRec, 600); }
                    else if (ev.error !== 'aborted' && _voiceActive) {
                        _setVoiceStatus('⚠️ Voice recognition error: ' + ev.error);
                        setTimeout(_startSpeechRec, 2000);
                    }
                };
                try { _recog.start(); } catch(e) {}
            }

            function _startListening() {
                if (!_voiceActive) return;
                if (_SpeechRec) { _startSpeechRec(); } else { _startVAD(); }
            }

            function _stopVoiceMode() {
                _voiceActive = false;
                window.speechSynthesis.cancel();
                if (_recog) { try { _recog.abort(); } catch(e){} _recog = null; }
                _stopVAD();
                _voiceBtn.textContent = '🔊';
                _voiceBtn.style.background = '';
                _voiceBtn.title = 'Voice conversation mode — speak to AI, AI speaks back';
                _setVoiceStatus('');
            }

            _voiceBtn.addEventListener('click', function() {
                if (_voiceActive) { _stopVoiceMode(); return; }
                if (!_SpeechRec && !_hasVAD) {
                    if (!_hasTTS) { alert('Your browser does not support voice features. Please use Chrome, Edge, Safari, or Firefox.'); return; }
                }
                _voiceActive = true;
                _voiceBtn.textContent = '🔇';
                _voiceBtn.style.background = 'var(--voice-active-bg, #d0ffd0)';
                _voiceBtn.title = 'Voice mode ON — click to stop';
                _startListening();
            });

            document.getElementById('close-chat').addEventListener('click', function() {
                if (_voiceActive) _stopVoiceMode();
            }, true);
        })();

    }

    window.ComservChat.voice = { wire: wire };
})();
