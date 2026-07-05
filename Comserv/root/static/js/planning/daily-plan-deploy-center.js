/**
 * planning/daily-plan-deploy-center.js
 * Deployment Control Center modal for /planning/daily page
 * Renamed from openDeployModal/closeDeployModal → openDeployControlCenter/closeDeployControlCenter
 * to avoid collision with daily-plan.js's openDeployModal().
 * Extracted from inline <script> in DailyPlan.tt — modular load via js_load.tt
 */
(function() {
    'use strict';

    var deployPollingInterval = null;
    var deployLastLogLength = 0;

    window.openDeployControlCenter = function() {
        var modal = document.getElementById('deploy-modal');
        if (!modal) return;
        modal.style.display = 'flex';
        var progressEl = document.getElementById('deploy-progress-container');
        if (progressEl) progressEl.style.display = 'none';
        var outputBox = document.getElementById('deploy-output-box');
        if (outputBox) outputBox.textContent = '';
        var startBtn = document.getElementById('deploy-start-btn');
        if (startBtn) startBtn.disabled = false;
        var cancelBtn = document.getElementById('deploy-cancel-btn');
        if (cancelBtn) cancelBtn.disabled = false;

        // Attempt to load saved credentials
        fetch('/admin/docker-load-credentials')
            .then(function(r) { return r.json(); })
            .then(function(data) {
                if (data.success) {
                    if (data.ssh_target) {
                        var targetEl = document.getElementById('deploy-ssh-target');
                        if (targetEl) targetEl.value = data.ssh_target;
                    }
                    if (data.ssh_password) {
                        var passEl = document.getElementById('deploy-ssh-password');
                        if (passEl) passEl.value = data.ssh_password;
                    }
                }
            })
            .catch(function(err) { console.log('Failed to load credentials:', err); });
    };

    window.closeDeployControlCenter = function() {
        if (deployPollingInterval) {
            clearInterval(deployPollingInterval);
            deployPollingInterval = null;
        }
        var modal = document.getElementById('deploy-modal');
        if (modal) modal.style.display = 'none';
    };

    window.toggleDeployForm = function() {
        var selected = document.querySelector('input[name="deploy_method"]:checked');
        if (!selected) return;
        var settings = document.getElementById('production-deploy-settings');
        if (!settings) return;
        settings.style.display = selected.value === 'production' ? 'flex' : 'none';
    };

    // Wire up radio change events for deploy form
    document.addEventListener('change', function(e) {
        if (e.target && e.target.name === 'deploy_method') {
            window.toggleDeployForm();
        }
    });

    function pollDeploymentProgress() {
        if (deployPollingInterval) clearInterval(deployPollingInterval);
        deployPollingInterval = setInterval(function() {
            fetch('/admin/docker-deploy-status')
                .then(function(r) { return r.json(); })
                .then(function(data) {
                    if (data.success) {
                        var outputBox = document.getElementById('deploy-output-box');
                        if (data.output && data.output.length > deployLastLogLength) {
                            var newText = data.output.substring(deployLastLogLength);
                            outputBox.textContent += newText;
                            outputBox.scrollTop = outputBox.scrollHeight;
                            deployLastLogLength = data.output.length;
                        }
                        if (!data.is_running) {
                            clearInterval(deployPollingInterval);
                            deployPollingInterval = null;
                            outputBox.textContent += '\\n\\n';
                            outputBox.textContent += '================================================================================\\n';
                            outputBox.textContent += '✅ DEPLOYMENT FINISHED AT ' + new Date().toLocaleTimeString() + '\\n';
                            outputBox.textContent += '================================================================================\\n';
                            outputBox.scrollTop = outputBox.scrollHeight;
                            var startBtn = document.getElementById('deploy-start-btn');
                            if (startBtn) startBtn.disabled = false;
                            var cancelBtn = document.getElementById('deploy-cancel-btn');
                            if (cancelBtn) cancelBtn.disabled = false;
                            var spinner = document.getElementById('deploy-status-spinner');
                            if (spinner) spinner.style.display = 'none';
                        }
                    }
                })
                .catch(function(err) { console.log('Error polling status:', err); });
        }, 2000);
    }

    window.startDeploymentAction = function() {
        var methodEl = document.querySelector('input[name="deploy_method"]:checked');
        if (!methodEl) return;
        var method = methodEl.value;
        var startBtn = document.getElementById('deploy-start-btn');
        var cancelBtn = document.getElementById('deploy-cancel-btn');
        var progressContainer = document.getElementById('deploy-progress-container');
        var outputBox = document.getElementById('deploy-output-box');
        var spinner = document.getElementById('deploy-status-spinner');

        if (startBtn) startBtn.disabled = true;
        if (cancelBtn) cancelBtn.disabled = true;
        if (progressContainer) progressContainer.style.display = 'flex';
        if (outputBox) outputBox.textContent = 'Initializing deployment...\\n';
        if (spinner) spinner.style.display = 'flex';

        if (method === 'production') {
            var sshTarget = document.getElementById('deploy-ssh-target');
            var sshPassword = document.getElementById('deploy-ssh-password');
            var deployMode = document.getElementById('deploy-mode-select');
            var st = sshTarget ? sshTarget.value.trim() : '';
            var sp = sshPassword ? sshPassword.value : '';
            var dm = deployMode ? deployMode.value : 'full';

            if (outputBox) outputBox.textContent += 'Starting background Docker Hub deployment [mode: ' + dm + '] to ' + st + '...\\n';

            fetch('/admin/docker-deploy-to-production', {
                method: 'POST',
                headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
                body: 'ssh_target=' + encodeURIComponent(st) + '&ssh_password=' + encodeURIComponent(sp) + '&deploy_mode=' + encodeURIComponent(dm) + '&trigger_source=DailyPlan'
            })
            .then(function(r) { return r.json(); })
            .then(function(data) {
                if (data.success) {
                    if (outputBox) outputBox.textContent += '✅ Background deploy process successfully started.\\n';
                    if (outputBox) outputBox.textContent += 'Log file: ' + (data.log_file || 'n/a') + '\\n';
                    if (outputBox) outputBox.textContent += 'Streaming status output below:\\n\\n';
                    deployLastLogLength = 0;
                    pollDeploymentProgress();
                } else {
                    if (outputBox) outputBox.textContent += '❌ FAILED: ' + (data.error || 'Unknown error') + '\\n';
                    if (startBtn) startBtn.disabled = false;
                    if (cancelBtn) cancelBtn.disabled = false;
                    if (spinner) spinner.style.display = 'none';
                }
            })
            .catch(function(err) {
                if (outputBox) outputBox.textContent += '❌ REQUEST ERROR: ' + err.message + '\\n';
                if (startBtn) startBtn.disabled = false;
                if (cancelBtn) cancelBtn.disabled = false;
                if (spinner) spinner.style.display = 'none';
            });
        } else {
            if (outputBox) outputBox.textContent += 'Triggering synchronous local workstation deployment...\\n';
            if (outputBox) outputBox.textContent += 'Please wait, output will display upon completion...\\n\\n';

            fetch('/admin/docker/deploy', {
                method: 'POST',
                headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
                body: 'todo_record_id=' + encodeURIComponent(todoId || 0) + '&trigger_source=DailyPlan-local'
            })
            .then(function(r) { return r.json(); })
            .then(function(data) {
                if (data.success) {
                    if (outputBox) outputBox.textContent += '✅ LOCAL DEPLOY COMPLETED SUCCESSFULLY!\\n\\n';
                    if (outputBox) outputBox.textContent += data.output || '';
                } else {
                    if (outputBox) outputBox.textContent += '❌ LOCAL DEPLOY HAD ERRORS:\\n\\n';
                    if (outputBox) outputBox.textContent += data.output || data.message || 'Unknown error';
                }
                if (startBtn) startBtn.disabled = false;
                if (cancelBtn) cancelBtn.disabled = false;
                if (spinner) spinner.style.display = 'none';
            })
            .catch(function(err) {
                if (outputBox) outputBox.textContent += '❌ REQUEST ERROR: ' + err.message + '\\n';
                if (startBtn) startBtn.disabled = false;
                if (cancelBtn) cancelBtn.disabled = false;
                if (spinner) spinner.style.display = 'none';
            });
        }
    };

})();