// ai-chat/audio-backup.js -- V2 module (extracted from local-chat.js)
// Local audio-backup store: an IndexedDB `AudioInspectionBackupDB` that caches
// voice/hive-inspection recordings so they can be re-transcribed or downloaded
// later. Renders the "local audio backups" list inside the chat panel.
//
// This was a self-contained block inside ComservAIChat's main IIFE. It reaches
// into the closure only for transcribeAudioFile() (used by the per-recording
// "re-transcribe" button), injected via .init. Exposed as
// ComservChat.audioBackup and wired from local-chat.js (a) right after the
// closure defines the audio helpers, and (b) from the voice module's wire() so
// the mic recorder can persist recordings. Behavior is 1:1 with the original.
(function () {
    window.ComservChat = window.ComservChat || {};

    // Injected dependency -- the chat-core transcribeAudioFile() (closure-private
    // in local-chat.js). Used by the per-recording re-transcribe button.
    var transcribeAudioFile = null;

    function init(ctx) {
        transcribeAudioFile = ctx && ctx.transcribeAudioFile;
    }

    // ── Local Audio Backup Store (IndexedDB) ───────────────────────────────────
    const dbName = 'AudioInspectionBackupDB';
    const storeName = 'recordings';

    function _openAudioDB() {
        return new Promise((resolve, reject) => {
            const request = indexedDB.open(dbName, 1);
            request.onerror = (e) => reject(e.target.error);
            request.onsuccess = (e) => resolve(e.target.result);
            request.onupgradeneeded = (e) => {
                const db = e.target.result;
                if (!db.objectStoreNames.contains(storeName)) {
                    db.createObjectStore(storeName, { keyPath: 'id' });
                }
            };
        });
    }

    async function _saveAudioBackup(id, file, elapsed) {
        try {
            const db = await _openAudioDB();
            const tx = db.transaction(storeName, 'readwrite');
            const store = tx.objectStore(storeName);
            const record = {
                id: id,
                fileName: file.name,
                type: file.type,
                blob: file,
                elapsed: elapsed,
                timestamp: Date.now(),
                status: 'pending'
            };
            store.put(record);
            return new Promise((resolve, reject) => {
                tx.oncomplete = () => resolve(record);
                tx.onerror = (e) => reject(e.target.error);
            });
        } catch (err) {
            console.error('Failed to save local audio backup:', err);
        }
    }

    async function _getAudioBackup(id) {
        try {
            const db = await _openAudioDB();
            const tx = db.transaction(storeName, 'readonly');
            const store = tx.objectStore(storeName);
            const req = store.get(id);
            return new Promise((resolve, reject) => {
                req.onsuccess = () => resolve(req.result);
                req.onerror = (e) => reject(e.target.error);
            });
        } catch (err) {
            console.error('Failed to get local audio backup:', err);
        }
    }

    async function _updateAudioBackupStatus(id, status) {
        try {
            const db = await _openAudioDB();
            const tx = db.transaction(storeName, 'readwrite');
            const store = tx.objectStore(storeName);
            const req = store.get(id);
            req.onsuccess = () => {
                const record = req.result;
                if (record) {
                    record.status = status;
                    store.put(record);
                }
            };
            return new Promise((resolve) => {
                tx.oncomplete = () => resolve();
            });
        } catch (err) {
            console.error('Failed to update local audio backup status:', err);
        }
    }

    async function _deleteAudioBackup(id) {
        try {
            const db = await _openAudioDB();
            const tx = db.transaction(storeName, 'readwrite');
            const store = tx.objectStore(storeName);
            store.delete(id);
            return new Promise((resolve) => {
                tx.oncomplete = () => resolve();
            });
        } catch (err) {
            console.error('Failed to delete local audio backup:', err);
        }
    }

    async function _listAudioBackups() {
        try {
            const db = await _openAudioDB();
            const tx = db.transaction(storeName, 'readonly');
            const store = tx.objectStore(storeName);
            const req = store.getAll();
            return new Promise((resolve, reject) => {
                req.onsuccess = () => resolve(req.result || []);
                req.onerror = (e) => reject(e.target.error);
            });
        } catch (err) {
            console.error('Failed to list local audio backups:', err);
            return [];
        }
    }

    async function _cleanupOldAudioBackups() {
        try {
            const backups = await _listAudioBackups();
            const cutoff = Date.now() - 7 * 24 * 60 * 60 * 1000; // 7 days
            for (const b of backups) {
                if (b.timestamp < cutoff || b.status === 'uploaded') {
                    await _deleteAudioBackup(b.id);
                }
            }
        } catch (e) {
            console.error('Failed to cleanup old audio backups:', e);
        }
    }

    async function _renderLocalAudioBackups() {
        const container = document.getElementById('local-audio-backups-container');
        if (!container) return;

        const backups = await _listAudioBackups();
        const pending = backups.filter(b => b.status !== 'uploaded');

        if (pending.length === 0) {
            container.style.display = 'none';
            container.innerHTML = '';
            return;
        }

        container.style.display = 'block';
        container.innerHTML = '<div style="font-weight:bold;margin-bottom:5px;border-bottom:1px solid var(--border-color,#ddd);padding-bottom:3px;display:flex;justify-content:space-between;align-items:center;">' +
            '<span>⚠️ Unsent Voice Recordings (' + pending.length + ')</span>' +
            '<button id="close-backups-btn" style="background:none;border:none;cursor:pointer;font-size:1.1em;padding:0;color:var(--text-muted-color,#888);">×</button>' +
            '</div>';

        // Add close button listener
        container.querySelector('#close-backups-btn').addEventListener('click', () => {
            container.style.display = 'none';
        });

        const listDiv = document.createElement('div');
        listDiv.style.cssText = 'max-height:120px;overflow-y:auto;display:flex;flex-direction:column;gap:4px;';

        pending.forEach(b => {
            const item = document.createElement('div');
            item.style.cssText = 'display:flex;align-items:center;justify-content:space-between;gap:6px;padding:3px;background:var(--table-header-bg,#f9f9f9);border-radius:3px;border:1px solid var(--border-color,#eee);';

            const dateStr = new Date(b.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) + ' (' + b.elapsed + ')';
            
            const info = document.createElement('span');
            info.style.cssText = 'white-space:nowrap;overflow:hidden;text-overflow:ellipsis;flex:1;font-size:0.9em;';
            info.textContent = dateStr;
            item.appendChild(info);

            const btnGroup = document.createElement('div');
            btnGroup.style.cssText = 'display:flex;gap:3px;';

            // Retry button
            const retryBtn = document.createElement('button');
            retryBtn.textContent = 'Retry';
            retryBtn.title = 'Retry upload and transcription';
            retryBtn.style.cssText = 'padding:2px 5px;font-size:0.8em;cursor:pointer;background:var(--accent-color, #0077cc);color:var(--background-color, #fff);border:none;border-radius:3px;';
            retryBtn.addEventListener('click', async () => {
                retryBtn.disabled = true;
                retryBtn.textContent = '...';
                transcribeAudioFile(b.blob, b.id);
            });
            btnGroup.appendChild(retryBtn);

            // Download/Save button
            const dlBtn = document.createElement('button');
            dlBtn.textContent = 'Save';
            dlBtn.title = 'Download raw audio file to your device';
            dlBtn.style.cssText = 'padding:2px 5px;font-size:0.8em;cursor:pointer;background:var(--success-color, #28a745);color:var(--background-color, #fff);border:none;border-radius:3px;';
            dlBtn.addEventListener('click', () => {
                const url = URL.createObjectURL(b.blob);
                const a = document.createElement('a');
                a.href = url;
                a.download = b.fileName;
                document.body.appendChild(a);
                a.click();
                document.body.removeChild(a);
                URL.revokeObjectURL(url);
            });
            btnGroup.appendChild(dlBtn);

            // Delete button
            const delBtn = document.createElement('button');
            delBtn.textContent = 'Delete';
            delBtn.title = 'Remove local backup';
            delBtn.style.cssText = 'padding:2px 5px;font-size:0.8em;cursor:pointer;background:var(--danger-color, #dc3545);color:var(--background-color, #fff);border:none;border-radius:3px;';
            delBtn.addEventListener('click', async () => {
                if (confirm('Delete this local recording?')) {
                    await _deleteAudioBackup(b.id);
                    _renderLocalAudioBackups();
                }
            });
            btnGroup.appendChild(delBtn);

            item.appendChild(btnGroup);
            listDiv.appendChild(item);
        });

        container.appendChild(listDiv);
    }

    // Public API -- called from local-chat.js (voice wire + DOMContentLoaded init)
    // and from ComservChat.audioBackup.init({ transcribeAudioFile: ... }).
    window.ComservChat.audioBackup = {
        init:                  init,
        openAudioDB:           _openAudioDB,
        saveAudioBackup:       _saveAudioBackup,
        getAudioBackup:        _getAudioBackup,
        updateAudioBackupStatus: _updateAudioBackupStatus,
        deleteAudioBackup:     _deleteAudioBackup,
        listAudioBackups:      _listAudioBackups,
        cleanupOldAudioBackups: _cleanupOldAudioBackups,
        renderLocalAudioBackups: _renderLocalAudioBackups
    };
})();
