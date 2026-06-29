// root/static/js/ai2editor/commit-ui.js
// Commit UI logic for AI2 editor sidebar (PyCharm style)

(function() {
    const gitSection = document.getElementById('git-section');

    function showCommitForm() {
        gitSection.innerHTML = `
            <h4>GIT</h4>
            <div class="commit-panel">
                <div style="font-size:11px; color:#888; margin-bottom:4px;">Staged Changes</div>
                <ul style="margin:4px 0; padding-left:16px; font-size:12px; color:#ddd;">
                    <li>editing_widget_popup.tt</li>
                </ul>
                <textarea id="commit-message" placeholder="Commit message..." style="width:100%; height:60px; background:#1e1f22; color:#ddd; border:1px solid #555; border-radius:3px; font-size:12px; resize:vertical;"></textarea>
                <button id="do-commit-btn" style="margin-top:6px; width:100%; background:#0e639c; color:white; border:none; padding:4px 10px; border-radius:3px; cursor:pointer; font-size:12px;">Commit</button>
                <button id="cancel-commit-btn" style="margin-top:4px; width:100%; background:#555; color:white; border:none; padding:4px 10px; border-radius:3px; cursor:pointer; font-size:12px;">Cancel</button>
            </div>
        `;

        document.getElementById('do-commit-btn').addEventListener('click', () => {
            alert('Committed!');
            showCommitButton();
        });

        document.getElementById('cancel-commit-btn').addEventListener('click', () => {
            showCommitButton();
        });
    }

    function showCommitButton() {
        gitSection.innerHTML = `
            <h4>GIT</h4>
            <button id="commit-btn" class="commit-btn">Commit Changes</button>
        `;
        document.getElementById('commit-btn').addEventListener('click', showCommitForm);
    }

    // Initial binding
    const initialBtn = document.getElementById('commit-btn');
    if (initialBtn) {
        initialBtn.addEventListener('click', showCommitForm);
    }
})();
