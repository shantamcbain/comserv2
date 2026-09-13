<div id="2026-08-30-helpdesk-spam-hardening" class="cl-entry">
<h3>2026-08-30 — HelpDesk spam hardening (honeypot, math, content filter, rate limit)</h3>
<p class="doc-body"><strong>What.</strong> Public HelpDesk ticket submit and contact forms now share an anti-spam guard: hidden honeypot (<code>website</code>), guest-only session math challenge (answer not exposed in HTML), content block for crypto/phishing patterns (Coinbase/graph.org style), and a 5-per-hour session rate limit. Contact POST route fixed so <code>/HelpDesk/contact/send</code> actually dispatches.</p>
<p class="doc-body"><strong>Why.</strong> Ticket CSC-20260830-2900 (guest Coinbase phishing subject). First free-model pass left <code>contact_send</code> indented (not a Catalyst action), used invalid <code>PathPart('contact/send')</code>, leaked the math answer in a hidden field, and skipped the math check when the session sum was empty.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Controller/HelpDesk.pm</code>, <code>Comserv/root/CSC/HelpDesk/new_ticket.tt</code>, <code>Comserv/root/CSC/HelpDesk/contact.tt</code></p>
</div>
