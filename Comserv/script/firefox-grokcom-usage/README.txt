Comserv grok.com usage (Firefox)

Watches the grok.com Settings → Usage tab you keep open. On each change
(and every 15s while the tab is open) it records Build % and Chat % only.

Writes:
  Comserv/root/static/ai/grokcom_usage.json           current
  Comserv/root/static/ai/grokcom_usage_history.jsonl  each change

Permanent install on this Snap Firefox profile (same as other @local add-ons):
  ~/snap/firefox/common/.mozilla/firefox/63c6yk5x.default/extensions/grokcom-usage@comserv.local.xpi
  ~/snap/firefox/common/.mozilla/native-messaging-hosts/comserv_grokcom_usage.json

Firefox may need a browser restart (not the Comserv app) to enable a new
sideloaded xpi. Toolbar popup shows the last reading and recent changes.

v1.4.7 (Oct 31 2026): auto-reload of the usage tab
  Firefox throttles background tabs, so a usage tab left in the background
  kept showing old numbers. The add-on now remembers which grok.com tab showed
  the usage numbers and reloads it every 5 minutes (skipped while it is the
  tab you are looking at). Keep the usage page open on a URL that shows the
  usage panel directly after a reload; if a reload lands somewhere without the
  numbers, nothing is posted until you open the usage panel again.

Reloading the temporary add-on after a change (or after every reboot):
  1. In Firefox open  about:debugging#/runtime/this-firefox
  2. Find "Comserv grok.com usage" and click Reload
     (if it is not listed: "Load Temporary Add-on..." and pick
      script/firefox-grokcom-usage/manifest.json or the .xpi).
  3. Check the version shows 1.4.7, then reload the grok.com usage tab once.
Build (same as before): zip -j grokcom-usage@comserv.local.xpi manifest.json
  background.js content.js popup.html popup.js
