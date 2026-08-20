<div id="2025-05-20-template-error-fix-and-docs-organization" class="cl-entry">
<h3>Template</h3>
<h1 id="template-error-fix-and-documentation-organization">Template
Error Fix and Documentation Organization</h1>
<p><strong>File:</strong>
/home/shanta/PycharmProjects/comserv/Comserv/docs/2025-05-20-template-error-fix-and-docs-organization.md<br />
<strong>Date:</strong> May 20, 2025<br />
<strong>Author:</strong> System Administrator<br />
<strong>Status:</strong> Implemented</p>
<h2 id="overview">Overview</h2>
<p>This document outlines two important changes made to the Comserv
system:</p>
<ol type="1">
<li>Fixed a template error in the pagetop.tt file that was causing
numeric comparison errors</li>
<li>Created a script to organize documentation files by moving them from
the Comserv root directory to the docs directory</li>
</ol>
<h2 id="template-error-fix">1. Template Error Fix</h2>
<h3 id="issue-description">Issue Description</h3>
<p>The system logs were showing the following error repeatedly:</p>
<pre><code>Argument &quot;&quot; isn&#39;t numeric in numeric gt (&gt;) at /home/comserv/public_html/comserv2/Comserv/root/pagetop.tt line 55.</code></pre>
<p>This error occurred when the template tried to perform a numeric
comparison on <code>c.session.roles.grep('admin').size</code> when
<code>c.session.roles</code> was either undefined or not an array.</p>
<h3 id="solution">Solution</h3>
<p>Modified line 55 in <code>pagetop.tt</code> to include proper checks
before attempting to use the <code>grep</code> method:</p>
<pre class="tt"><code>&#91;% SET is_admin = c.session.roles.defined &amp;&amp; c.session.roles.size &amp;&amp; c.session.roles.grep(&#39;admin&#39;).size &gt; 0 ? 1 : 0 %&#93;</code></pre>
<p>This change ensures that: 1. <code>c.session.roles</code> is defined
2. <code>c.session.roles</code> has a size (meaning it’s an array with
elements) 3. Only then tries to grep for ‘admin’ and check if the size
is greater than 0</p>
<p>The ternary operator (<code>? 1 : 0</code>) ensures that
<code>is_admin</code> is always set to either 1 or 0, which is what the
template expects.</p>
<h3 id="impact">Impact</h3>
<p>This fix prevents template rendering errors when users are not
properly logged in or when session data is incomplete. The error was
appearing for various site names including BMaster, Forager, and
CSC.</p>
<h2 id="documentation-organization">2. Documentation Organization</h2>
<h3 id="issue-description-1">Issue Description</h3>
<p>The Comserv root directory contained numerous markdown documentation
files that should be organized in the dedicated docs directory. These
included:</p>
<ul>
<li>Files with “Formatting title from:” prefix</li>
<li>Date-based update files (starting with years like 2024, 2025)</li>
<li>Other documentation files with keywords like “fix”, “documentation”,
“system”, “guide”, or “management”</li>
</ul>
<h3 id="solution-1">Solution</h3>
<p>Created a bash script (<code>move_md_files.sh</code>) to
systematically move documentation files from the Comserv root directory
to the docs directory. The script:</p>
<ol type="1">
<li>Moves files with the “Formatting title from:” prefix to the docs
directory, using the original filename</li>
<li>Moves date-based update files (starting with years like 2024,
2025)</li>
<li>Moves other documentation files with specific keywords in their
names</li>
<li>Skips certain system files that should remain in the root (like
THEME_SYSTEM files and ROUTING_FIXES)</li>
<li>Logs all operations to a log file for review</li>
</ol>
<div class="sourceCode" id="cb3"><pre
class="sourceCode bash"><code class="sourceCode bash"><span id="cb3-1"><a href="#cb3-1" aria-hidden="true" tabindex="-1"></a><span class="co">#!/bin/bash</span></span>
<span id="cb3-2"><a href="#cb3-2" aria-hidden="true" tabindex="-1"></a></span>
<span id="cb3-3"><a href="#cb3-3" aria-hidden="true" tabindex="-1"></a><span class="co"># Script to move markdown files from Comserv root to Comserv/docs</span></span>
<span id="cb3-4"><a href="#cb3-4" aria-hidden="true" tabindex="-1"></a><span class="co"># This includes files with &quot;Formatting title from:&quot; prefix and date-based update files</span></span>
<span id="cb3-5"><a href="#cb3-5" aria-hidden="true" tabindex="-1"></a></span>
<span id="cb3-6"><a href="#cb3-6" aria-hidden="true" tabindex="-1"></a><span class="va">SOURCE_DIR</span><span class="op">=</span><span class="st">&quot;/home/shanta/PycharmProjects/comserv/Comserv&quot;</span></span>
<span id="cb3-7"><a href="#cb3-7" aria-hidden="true" tabindex="-1"></a><span class="va">DEST_DIR</span><span class="op">=</span><span class="st">&quot;/home/shanta/PycharmProjects/comserv/Comserv/docs&quot;</span></span>
<span id="cb3-8"><a href="#cb3-8" aria-hidden="true" tabindex="-1"></a></span>
<span id="cb3-9"><a href="#cb3-9" aria-hidden="true" tabindex="-1"></a><span class="co"># Create a log file</span></span>
<span id="cb3-10"><a href="#cb3-10" aria-hidden="true" tabindex="-1"></a><span class="va">LOG_FILE</span><span class="op">=</span><span class="st">&quot;/home/shanta/PycharmProjects/comserv/move_md_files.log&quot;</span></span>
<span id="cb3-11"><a href="#cb3-11" aria-hidden="true" tabindex="-1"></a><span class="bu">echo</span> <span class="st">&quot;Starting file move operation at </span><span class="va">$(</span><span class="fu">date</span><span class="va">)</span><span class="st">&quot;</span> <span class="op">&gt;</span> <span class="st">&quot;</span><span class="va">$LOG_FILE</span><span class="st">&quot;</span></span>
<span id="cb3-12"><a href="#cb3-12" aria-hidden="true" tabindex="-1"></a></span>
<span id="cb3-13"><a href="#cb3-13" aria-hidden="true" tabindex="-1"></a><span class="co"># Move files with &quot;Formatting title from:&quot; prefix</span></span>
<span id="cb3-14"><a href="#cb3-14" aria-hidden="true" tabindex="-1"></a><span class="cf">for</span> file <span class="kw">in</span> <span class="st">&quot;</span><span class="va">$SOURCE_DIR</span><span class="st">&quot;</span>/Formatting<span class="pp">*</span><span class="kw">;</span> <span class="cf">do</span></span>
<span id="cb3-15"><a href="#cb3-15" aria-hidden="true" tabindex="-1"></a>  <span class="cf">if</span> <span class="bu">[</span> <span class="ot">-f</span> <span class="st">&quot;</span><span class="va">$file</span><span class="st">&quot;</span> <span class="bu">]</span><span class="kw">;</span> <span class="cf">then</span></span>
<span id="cb3-16"><a href="#cb3-16" aria-hidden="true" tabindex="-1"></a>    <span class="co"># Extract the original filename</span></span>
<span id="cb3-17"><a href="#cb3-17" aria-hidden="true" tabindex="-1"></a>    <span class="va">original_name</span><span class="op">=</span><span class="va">$(</span><span class="bu">echo</span> <span class="st">&quot;</span><span class="va">$file</span><span class="st">&quot;</span> <span class="kw">|</span> <span class="fu">sed</span> <span class="st">&#39;s/.*Formatting title from: //&#39;</span><span class="va">)</span></span>
<span id="cb3-18"><a href="#cb3-18" aria-hidden="true" tabindex="-1"></a>    </span>
<span id="cb3-19"><a href="#cb3-19" aria-hidden="true" tabindex="-1"></a>    <span class="co"># Check if the file already exists in the destination</span></span>
<span id="cb3-20"><a href="#cb3-20" aria-hidden="true" tabindex="-1"></a>    <span class="cf">if</span> <span class="bu">[</span> <span class="ot">-f</span> <span class="st">&quot;</span><span class="va">$DEST_DIR</span><span class="st">/</span><span class="va">$original_name</span><span class="st">&quot;</span> <span class="bu">]</span><span class="kw">;</span> <span class="cf">then</span></span>
<span id="cb3-21"><a href="#cb3-21" aria-hidden="true" tabindex="-1"></a>      <span class="bu">echo</span> <span class="st">&quot;File already exists: </span><span class="va">$original_name</span><span class="st"> - skipping&quot;</span> <span class="op">&gt;&gt;</span> <span class="st">&quot;</span><span class="va">$LOG_FILE</span><span class="st">&quot;</span></span>
<span id="cb3-22"><a href="#cb3-22" aria-hidden="true" tabindex="-1"></a>    <span class="cf">else</span></span>
<span id="cb3-23"><a href="#cb3-23" aria-hidden="true" tabindex="-1"></a>      <span class="co"># Move the file to the docs directory with its original name</span></span>
<span id="cb3-24"><a href="#cb3-24" aria-hidden="true" tabindex="-1"></a>      <span class="fu">mv</span> <span class="st">&quot;</span><span class="va">$file</span><span class="st">&quot;</span> <span class="st">&quot;</span><span class="va">$DEST_DIR</span><span class="st">/</span><span class="va">$original_name</span><span class="st">&quot;</span></span>
<span id="cb3-25"><a href="#cb3-25" aria-hidden="true" tabindex="-1"></a>      <span class="bu">echo</span> <span class="st">&quot;Moved: </span><span class="va">$file</span><span class="st"> -&gt; </span><span class="va">$DEST_DIR</span><span class="st">/</span><span class="va">$original_name</span><span class="st">&quot;</span> <span class="op">&gt;&gt;</span> <span class="st">&quot;</span><span class="va">$LOG_FILE</span><span class="st">&quot;</span></span>
<span id="cb3-26"><a href="#cb3-26" aria-hidden="true" tabindex="-1"></a>    <span class="cf">fi</span></span>
<span id="cb3-27"><a href="#cb3-27" aria-hidden="true" tabindex="-1"></a>  <span class="cf">fi</span></span>
<span id="cb3-28"><a href="#cb3-28" aria-hidden="true" tabindex="-1"></a><span class="cf">done</span></span>
<span id="cb3-29"><a href="#cb3-29" aria-hidden="true" tabindex="-1"></a></span>
<span id="cb3-30"><a href="#cb3-30" aria-hidden="true" tabindex="-1"></a><span class="co"># Move date-based update files (files that start with a year like 202*)</span></span>
<span id="cb3-31"><a href="#cb3-31" aria-hidden="true" tabindex="-1"></a><span class="cf">for</span> file <span class="kw">in</span> <span class="st">&quot;</span><span class="va">$SOURCE_DIR</span><span class="st">&quot;</span>/202<span class="pp">*</span>.md<span class="kw">;</span> <span class="cf">do</span></span>
<span id="cb3-32"><a href="#cb3-32" aria-hidden="true" tabindex="-1"></a>  <span class="cf">if</span> <span class="bu">[</span> <span class="ot">-f</span> <span class="st">&quot;</span><span class="va">$file</span><span class="st">&quot;</span> <span class="bu">]</span><span class="kw">;</span> <span class="cf">then</span></span>
<span id="cb3-33"><a href="#cb3-33" aria-hidden="true" tabindex="-1"></a>    <span class="va">filename</span><span class="op">=</span><span class="va">$(</span><span class="fu">basename</span> <span class="st">&quot;</span><span class="va">$file</span><span class="st">&quot;</span><span class="va">)</span></span>
<span id="cb3-34"><a href="#cb3-34" aria-hidden="true" tabindex="-1"></a>    </span>
<span id="cb3-35"><a href="#cb3-35" aria-hidden="true" tabindex="-1"></a>    <span class="co"># Check if the file already exists in the destination</span></span>
<span id="cb3-36"><a href="#cb3-36" aria-hidden="true" tabindex="-1"></a>    <span class="cf">if</span> <span class="bu">[</span> <span class="ot">-f</span> <span class="st">&quot;</span><span class="va">$DEST_DIR</span><span class="st">/</span><span class="va">$filename</span><span class="st">&quot;</span> <span class="bu">]</span><span class="kw">;</span> <span class="cf">then</span></span>
<span id="cb3-37"><a href="#cb3-37" aria-hidden="true" tabindex="-1"></a>      <span class="bu">echo</span> <span class="st">&quot;File already exists: </span><span class="va">$filename</span><span class="st"> - skipping&quot;</span> <span class="op">&gt;&gt;</span> <span class="st">&quot;</span><span class="va">$LOG_FILE</span><span class="st">&quot;</span></span>
<span id="cb3-38"><a href="#cb3-38" aria-hidden="true" tabindex="-1"></a>    <span class="cf">else</span></span>
<span id="cb3-39"><a href="#cb3-39" aria-hidden="true" tabindex="-1"></a>      <span class="co"># Move the file to the docs directory</span></span>
<span id="cb3-40"><a href="#cb3-40" aria-hidden="true" tabindex="-1"></a>      <span class="fu">mv</span> <span class="st">&quot;</span><span class="va">$file</span><span class="st">&quot;</span> <span class="st">&quot;</span><span class="va">$DEST_DIR</span><span class="st">/</span><span class="va">$filename</span><span class="st">&quot;</span></span>
<span id="cb3-41"><a href="#cb3-41" aria-hidden="true" tabindex="-1"></a>      <span class="bu">echo</span> <span class="st">&quot;Moved: </span><span class="va">$file</span><span class="st"> -&gt; </span><span class="va">$DEST_DIR</span><span class="st">/</span><span class="va">$filename</span><span class="st">&quot;</span> <span class="op">&gt;&gt;</span> <span class="st">&quot;</span><span class="va">$LOG_FILE</span><span class="st">&quot;</span></span>
<span id="cb3-42"><a href="#cb3-42" aria-hidden="true" tabindex="-1"></a>    <span class="cf">fi</span></span>
<span id="cb3-43"><a href="#cb3-43" aria-hidden="true" tabindex="-1"></a>  <span class="cf">fi</span></span>
<span id="cb3-44"><a href="#cb3-44" aria-hidden="true" tabindex="-1"></a><span class="cf">done</span></span>
<span id="cb3-45"><a href="#cb3-45" aria-hidden="true" tabindex="-1"></a></span>
<span id="cb3-46"><a href="#cb3-46" aria-hidden="true" tabindex="-1"></a><span class="co"># Move other documentation files that have &quot;fix&quot; or specific documentation terms in their names</span></span>
<span id="cb3-47"><a href="#cb3-47" aria-hidden="true" tabindex="-1"></a><span class="cf">for</span> file <span class="kw">in</span> <span class="st">&quot;</span><span class="va">$SOURCE_DIR</span><span class="st">&quot;</span>/<span class="pp">*</span>fix<span class="pp">*</span>.md <span class="st">&quot;</span><span class="va">$SOURCE_DIR</span><span class="st">&quot;</span>/<span class="pp">*</span>documentation<span class="pp">*</span>.md <span class="st">&quot;</span><span class="va">$SOURCE_DIR</span><span class="st">&quot;</span>/<span class="pp">*</span>system<span class="pp">*</span>.md <span class="st">&quot;</span><span class="va">$SOURCE_DIR</span><span class="st">&quot;</span>/<span class="pp">*</span>guide<span class="pp">*</span>.md <span class="st">&quot;</span><span class="va">$SOURCE_DIR</span><span class="st">&quot;</span>/<span class="pp">*</span>management<span class="pp">*</span>.md<span class="kw">;</span> <span class="cf">do</span></span>
<span id="cb3-48"><a href="#cb3-48" aria-hidden="true" tabindex="-1"></a>  <span class="co"># Skip if the pattern doesn&#39;t match any files</span></span>
<span id="cb3-49"><a href="#cb3-49" aria-hidden="true" tabindex="-1"></a>  <span class="bu">[</span> <span class="ot">-e</span> <span class="st">&quot;</span><span class="va">$file</span><span class="st">&quot;</span> <span class="bu">]</span> <span class="kw">||</span> <span class="cf">continue</span></span>
<span id="cb3-50"><a href="#cb3-50" aria-hidden="true" tabindex="-1"></a>  </span>
<span id="cb3-51"><a href="#cb3-51" aria-hidden="true" tabindex="-1"></a>  <span class="cf">if</span> <span class="bu">[</span> <span class="ot">-f</span> <span class="st">&quot;</span><span class="va">$file</span><span class="st">&quot;</span> <span class="bu">]</span><span class="kw">;</span> <span class="cf">then</span></span>
<span id="cb3-52"><a href="#cb3-52" aria-hidden="true" tabindex="-1"></a>    <span class="co"># Skip certain system files we want to keep in the root</span></span>
<span id="cb3-53"><a href="#cb3-53" aria-hidden="true" tabindex="-1"></a>    <span class="cf">if</span> <span class="kw">[[</span> <span class="st">&quot;</span><span class="va">$file</span><span class="st">&quot;</span> <span class="ot">==</span> <span class="pp">*</span><span class="st">&quot;THEME_SYSTEM&quot;</span><span class="pp">*</span> <span class="kw">||</span> <span class="st">&quot;</span><span class="va">$file</span><span class="st">&quot;</span> <span class="ot">==</span> <span class="pp">*</span><span class="st">&quot;NEW_THEME_SYSTEM&quot;</span><span class="pp">*</span> <span class="kw">||</span> <span class="st">&quot;</span><span class="va">$file</span><span class="st">&quot;</span> <span class="ot">==</span> <span class="pp">*</span><span class="st">&quot;ROUTING_FIXES&quot;</span><span class="pp">*</span> <span class="kw">]];</span> <span class="cf">then</span></span>
<span id="cb3-54"><a href="#cb3-54" aria-hidden="true" tabindex="-1"></a>      <span class="bu">echo</span> <span class="st">&quot;Keeping in root: </span><span class="va">$file</span><span class="st">&quot;</span> <span class="op">&gt;&gt;</span> <span class="st">&quot;</span><span class="va">$LOG_FILE</span><span class="st">&quot;</span></span>
<span id="cb3-55"><a href="#cb3-55" aria-hidden="true" tabindex="-1"></a>      <span class="cf">continue</span></span>
<span id="cb3-56"><a href="#cb3-56" aria-hidden="true" tabindex="-1"></a>    <span class="cf">fi</span></span>
<span id="cb3-57"><a href="#cb3-57" aria-hidden="true" tabindex="-1"></a>    </span>
<span id="cb3-58"><a href="#cb3-58" aria-hidden="true" tabindex="-1"></a>    <span class="va">filename</span><span class="op">=</span><span class="va">$(</span><span class="fu">basename</span> <span class="st">&quot;</span><span class="va">$file</span><span class="st">&quot;</span><span class="va">)</span></span>
<span id="cb3-59"><a href="#cb3-59" aria-hidden="true" tabindex="-1"></a>    </span>
<span id="cb3-60"><a href="#cb3-60" aria-hidden="true" tabindex="-1"></a>    <span class="co"># Check if the file already exists in the destination</span></span>
<span id="cb3-61"><a href="#cb3-61" aria-hidden="true" tabindex="-1"></a>    <span class="cf">if</span> <span class="bu">[</span> <span class="ot">-f</span> <span class="st">&quot;</span><span class="va">$DEST_DIR</span><span class="st">/</span><span class="va">$filename</span><span class="st">&quot;</span> <span class="bu">]</span><span class="kw">;</span> <span class="cf">then</span></span>
<span id="cb3-62"><a href="#cb3-62" aria-hidden="true" tabindex="-1"></a>      <span class="bu">echo</span> <span class="st">&quot;File already exists: </span><span class="va">$filename</span><span class="st"> - skipping&quot;</span> <span class="op">&gt;&gt;</span> <span class="st">&quot;</span><span class="va">$LOG_FILE</span><span class="st">&quot;</span></span>
<span id="cb3-63"><a href="#cb3-63" aria-hidden="true" tabindex="-1"></a>    <span class="cf">else</span></span>
<span id="cb3-64"><a href="#cb3-64" aria-hidden="true" tabindex="-1"></a>      <span class="co"># Move the file to the docs directory</span></span>
<span id="cb3-65"><a href="#cb3-65" aria-hidden="true" tabindex="-1"></a>      <span class="fu">mv</span> <span class="st">&quot;</span><span class="va">$file</span><span class="st">&quot;</span> <span class="st">&quot;</span><span class="va">$DEST_DIR</span><span class="st">/</span><span class="va">$filename</span><span class="st">&quot;</span></span>
<span id="cb3-66"><a href="#cb3-66" aria-hidden="true" tabindex="-1"></a>      <span class="bu">echo</span> <span class="st">&quot;Moved: </span><span class="va">$file</span><span class="st"> -&gt; </span><span class="va">$DEST_DIR</span><span class="st">/</span><span class="va">$filename</span><span class="st">&quot;</span> <span class="op">&gt;&gt;</span> <span class="st">&quot;</span><span class="va">$LOG_FILE</span><span class="st">&quot;</span></span>
<span id="cb3-67"><a href="#cb3-67" aria-hidden="true" tabindex="-1"></a>    <span class="cf">fi</span></span>
<span id="cb3-68"><a href="#cb3-68" aria-hidden="true" tabindex="-1"></a>  <span class="cf">fi</span></span>
<span id="cb3-69"><a href="#cb3-69" aria-hidden="true" tabindex="-1"></a><span class="cf">done</span></span>
<span id="cb3-70"><a href="#cb3-70" aria-hidden="true" tabindex="-1"></a></span>
<span id="cb3-71"><a href="#cb3-71" aria-hidden="true" tabindex="-1"></a><span class="bu">echo</span> <span class="st">&quot;File move operation completed at </span><span class="va">$(</span><span class="fu">date</span><span class="va">)</span><span class="st">&quot;</span> <span class="op">&gt;&gt;</span> <span class="st">&quot;</span><span class="va">$LOG_FILE</span><span class="st">&quot;</span></span>
<span id="cb3-72"><a href="#cb3-72" aria-hidden="true" tabindex="-1"></a><span class="bu">echo</span> <span class="st">&quot;See </span><span class="va">$LOG_FILE</span><span class="st"> for details of the operation.&quot;</span></span></code></pre></div>
<h3 id="impact-1">Impact</h3>
<p>This organization improves the project structure by: - Keeping all
documentation in a dedicated directory - Making it easier to find and
manage documentation files - Reducing clutter in the root directory -
Maintaining a consistent organization pattern for documentation</p>
<h2 id="execution-instructions">Execution Instructions</h2>
<h3 id="template-fix">Template Fix</h3>
<p>The template fix has been applied directly to the file and should
take effect immediately.</p>
<h3 id="documentation-organization-1">Documentation Organization</h3>
<p>To execute the documentation organization script:</p>
<ol type="1">
<li><p>Make the script executable:</p>
<div class="sourceCode" id="cb4"><pre
class="sourceCode bash"><code class="sourceCode bash"><span id="cb4-1"><a href="#cb4-1" aria-hidden="true" tabindex="-1"></a><span class="fu">chmod</span> +x /home/shanta/PycharmProjects/comserv/move_md_files.sh</span></code></pre></div></li>
<li><p>Run the script:</p>
<div class="sourceCode" id="cb5"><pre
class="sourceCode bash"><code class="sourceCode bash"><span id="cb5-1"><a href="#cb5-1" aria-hidden="true" tabindex="-1"></a><span class="ex">/home/shanta/PycharmProjects/comserv/move_md_files.sh</span></span></code></pre></div></li>
<li><p>Review the log file to confirm the operations:</p>
<div class="sourceCode" id="cb6"><pre
class="sourceCode bash"><code class="sourceCode bash"><span id="cb6-1"><a href="#cb6-1" aria-hidden="true" tabindex="-1"></a><span class="fu">cat</span> /home/shanta/PycharmProjects/comserv/move_md_files.log</span></code></pre></div></li>
</ol>
<h2 id="related-files">Related Files</h2>
<ul>
<li><code>/home/shanta/PycharmProjects/comserv/Comserv/root/pagetop.tt</code></li>
<li><code>/home/shanta/PycharmProjects/comserv/move_md_files.sh</code></li>
<li><code>/home/shanta/PycharmProjects/comserv/move_md_files.log</code>
(generated after script execution)</li>
</ul>

</div>
