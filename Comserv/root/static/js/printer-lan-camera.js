// Printer LAN camera: play the printer HTTP-FLV inside the page video box.
// Does not connect until the user clicks. The printer allows one viewer.
(function () {
  function setStatus(el, text) {
    if (el) el.textContent = text;
  }

  function destroy(player) {
    if (!player) return;
    try { player.pause(); } catch (e) {}
    try { player.unload(); } catch (e) {}
    try { player.detachMediaElement(); } catch (e) {}
    try { player.destroy(); } catch (e) {}
  }

  function boot() {
    var box = document.querySelector('[data-printer-flv]');
    if (!box) return;
    var video = box.querySelector('video');
    var play = box.querySelector('[data-printer-flv-play]');
    var stop = box.querySelector('[data-printer-flv-stop]');
    var status = box.querySelector('[data-printer-flv-status]');
    var url = box.getAttribute('data-flv-url');
    var player = null;

    if (!play || !video || !url) return;

    play.addEventListener('click', function () {
      if (!window.flvjs || !window.flvjs.isSupported()) {
        setStatus(status, 'This browser cannot play the stream in the page. Use VLC on the URL below.');
        return;
      }
      destroy(player);
      player = window.flvjs.createPlayer({
        type: 'flv',
        isLive: true,
        url: url
      }, {
        enableStashBuffer: false,
        stashInitialSize: 128
      });
      player.attachMediaElement(video);
      player.on(window.flvjs.Events.ERROR, function () {
        setStatus(status, 'No picture. Press Start camera, close any other viewer, then Show in page again.');
      });
      player.load();
      var started = player.play();
      if (started && typeof started.catch === 'function') {
        started.catch(function () {
          setStatus(status, 'Playback was blocked. Click Show in page again.');
        });
      }
      setStatus(status, 'Playing. This uses the printer’s one camera connection. Close VLC first.');
    });

    if (stop) {
      stop.addEventListener('click', function () {
        destroy(player);
        player = null;
        setStatus(status, 'Stopped. The camera connection is free.');
      });
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();
