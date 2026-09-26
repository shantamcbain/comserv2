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
