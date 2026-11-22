<li><strong>Chat HelpDesk reply / status / close (#2491):</strong> Chat-with-AI
and <code>/ai2/action</code> can now reply to an existing ticket (logged-in
owner or HelpDesk staff) and staff can set status or close it. Guests cannot.
AI Editor still skips these writes (#2495). No customer notification is sent
(#2494). Reuses the existing <code>TicketMessage</code> Result; no schema change.</li>
