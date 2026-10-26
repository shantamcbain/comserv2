<div id="2026-10-17-mail-source-local-or-server" class="cl-entry">
<h3>2026-10-17 — Invoice mail reads the local mail dir or a saved mail server</h3>
<p class="doc-body"><strong>What.</strong> Classification no longer opens a hardcoded workstation mail path. It reads <code>~/Maildir</code> only when that directory exists on the computer running the app, and it reads every mailbox this site has saved. A site such as CSC can save several addresses; adding one does not replace the others.</p>
<p class="doc-body"><strong>Why.</strong> Production has no mail and never will. A developer on the machine that holds the mail directory can read it locally. Any other user gives the app the mail server address and the mailbox credentials. The password is encrypted and is not written to the watch-list file.</p>
<p class="doc-body"><strong>Files.</strong> <code>Util/MailInvoiceClassifier.pm</code>, <code>Controller/Mail.pm</code>, <code>Controller/Inventory.pm</code>, <code>Controller/Inventory/PurchaseOrder.pm</code>, <code>Result/UserMailbox.pm</code>, <code>root/Inventory/email/setup.tt</code></p>
</div>
