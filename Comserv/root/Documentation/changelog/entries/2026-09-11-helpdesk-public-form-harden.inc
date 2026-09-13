<div id="2026-09-11-helpdesk-public-form-harden" class="cl-entry">
<h3>2026-09-11 — Harden HelpDesk public contact/guest forms</h3>
<p class="doc-body"><strong>What.</strong> Tightened public HelpDesk anti-spam: link-only and promo-profile detection in <code>_looks_like_spam_content</code>, session rate limit 3/hour, rolling per-IP limit 5/hour under <code>/tmp/comserv_hd_public_rate/</code>, and spam-guard order honeypot → rate → content → guest math. Ticket form prefers <code>num1</code>/<code>num2</code> like contact.</p>
<p class="doc-body"><strong>Why.</strong> CSC-20260911-6270 — promo/profile URL-only posts were slipping past crypto-pattern filters; session-only rate limits were too high and easy to rotate.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Controller/HelpDesk.pm</code> · <code>root/CSC/HelpDesk/new_ticket.tt</code></p>
</div>
