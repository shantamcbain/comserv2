<h3>2026-09-14 — Editor file reader now rejects binary files with clear error</h3>
<ul>
    <li><strong>Fix:</strong> <code>EditorFile::read_file</code> crashed with <code>malformed or illegal unicode character</code> when the Code Editor popup loaded a binary file (e.g. <code>.db-shm</code>) that couldn't be decoded as UTF-8. The underlying cause: Perl's <code>:utf8</code> IO layer slurped binary bytes without validation, then <code>encode_json</code> choked on the malformed string.</li>
    <li><strong>Change:</strong> Reads raw bytes (<code>:raw</code>) then explicitly decodes via <code>Encode::decode(FB_CROAK)</code>. Non-text files now return a clean 4xx error instead of crashing with a 500.</li>
</ul>