/*
 * Custom creation progress panel.
 *
 * The preview runs in a background worker (see Controller/CustomCreation.pm).
 * This polls /customcreation/status/<job> once a second and shows the stage,
 * elapsed seconds and stage history, so a slow model is visibly slow instead
 * of looking like a dead page. On success it moves to the result page; on
 * failure it prints the error and everything that was tried.
 */
(function () {
  'use strict';

  var root = document.getElementById('cc-progress');
  if (!root) { return; }

  var token = root.getAttribute('data-token');
  if (!token) { return; }

  var stageEl = root.querySelector('.cc-stage');
  var elapsedEl = root.querySelector('.cc-elapsed');
  var logEl = root.querySelector('.cc-log');
  var errorBox = root.querySelector('.cc-error');
  var errorMsg = root.querySelector('.cc-error-msg');
  var triedWrap = root.querySelector('.cc-tried-wrap');
  var triedList = root.querySelector('.cc-tried');

  var started = Date.now();
  // The template already printed the stages the job had when the page was
  // built; start after those so polling does not repeat them.
  var rendered = logEl ? logEl.querySelectorAll('li').length : 0;
  var timer = null;

  function appendLog(label) {
    if (!logEl || !label) { return; }
    var li = document.createElement('li');
    li.textContent = label;
    logEl.appendChild(li);
  }

  function tick() {
    if (elapsedEl) {
      elapsedEl.textContent = Math.round((Date.now() - started) / 1000);
    }
  }

  function showError(data) {
    if (timer) { clearInterval(timer); }
    if (stageEl) { stageEl.textContent = 'Nothing was generated'; }
    if (errorBox) { errorBox.style.display = ''; }
    if (errorMsg) { errorMsg.textContent = data.error || 'No STL was produced.'; }

    var tried = data.tried || [];
    if (tried.length && triedWrap && triedList) {
      triedWrap.style.display = '';
      tried.forEach(function (t) { 
        var li = document.createElement('li');
        li.textContent = t;
        triedList.appendChild(li);
      });
    }
    if (data.detail && errorMsg) {
      var p = document.createElement('p');
      p.className = 'doc-muted';
      p.textContent = data.detail;
      errorMsg.appendChild(p);
    }
  }

  function poll() {
    var url = '/customcreation/status/' + encodeURIComponent(token);
    fetch(url, { headers: { 'Accept': 'application/json' }, cache: 'no-store' })
      .then(function (r) { return r.json(); })
      .then(function (data) {
        tick();

        if (data.label && stageEl && stageEl.textContent !== data.label) {
          stageEl.textContent = data.label;
        }
        var entries = data.log || [];
        while (rendered < entries.length) {
          appendLog(entries[rendered] && entries[rendered].label);
          rendered++;
        }

        if (data.done) {
          if (data.ok && data.preview_url) {
            if (stageEl) { stageEl.textContent = data.label || 'STL ready'; }
            window.location.href = data.preview_url;
            return;
          }
          showError(data);
          return;
        }
        setTimeout(poll, 1000);
      })
      .catch(function () {
        // A single failed poll is not the end of the job: keep watching.
        setTimeout(poll, 2000);
      });
  }

  timer = setInterval(tick, 1000);
  poll();
})();
