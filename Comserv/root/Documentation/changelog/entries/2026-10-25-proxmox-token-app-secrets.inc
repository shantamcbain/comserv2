<div id="2026-10-25-proxmox-token-app-secrets" class="cl-entry">
<h3>2026-10-25 — Proxmox API token stored encrypted in app_secrets</h3>
<p class="doc-body"><strong>What.</strong> Submitting the existing add-server form encrypts <code>token_value</code> with <code>Comserv::Util::Encryption</code> (namespace <code>proxmox</code>) and writes only the <code>ENC:</code> ciphertext to <code>app_secrets</code> as <code>proxmox_token:<server_id></code>. Reads decrypt through the same module. Non-secret fields stay in <code>config/proxmox_credentials.json</code>. The credentials file path now points at that file.</p>
<p class="doc-body"><strong>Why.</strong> The token was plaintext in a JSON file the save path did not even write. <code>api_tokens.token_hash</code> is a one-way hash and cannot be decrypted, so it is the wrong table.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Util/ProxmoxCredentials.pm</code></p>
</div>
