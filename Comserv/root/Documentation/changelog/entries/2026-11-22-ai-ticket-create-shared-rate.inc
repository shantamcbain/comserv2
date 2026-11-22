<div id="2026-11-22-ai-ticket-create-shared-rate" class="cl-entry">
<h3>2026-11-22 — Chat HelpDesk ticket create uses the same spam rate and honeypot as the public forms</h3>
<p class="doc-body"><strong>What.</strong> Creating a HelpDesk ticket from Chat-with-AI or an AI action now fails closed on the same honeypot and session/IP rate limits as the public contact and ticket forms (3 per session per hour, 5 per IP per hour). Promotional content is still quarantined for staff review, not deleted. Guests cannot set high or critical priority through chat.</p>
<p class="doc-body"><strong>Why.</strong> Todo #2490 / follow-up to CSC-20261012-0420. The AI path already scored content, but a guest could still flood tickets from chat because rate and honeypot lived only on the web form.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Util/SpamGuard.pm</code>, <code>lib/Comserv/Model/AI2/HelpDeskTicketCreate.pm</code>, <code>lib/Comserv/Model/AI2/Actions.pm</code>, <code>t/spam_guard.t</code>, <code>t/model_ai2_helpdesk_ticket_create.t</code></p>
</div>
