<div id="2024-08-controller-fixes" class="cl-entry">
<h3>Controller Fixes - August</h3>
<h1 id="controller-fixes---august-2024">Controller Fixes - August
2024</h1>
<h2 id="overview">Overview</h2>
<p>This document details the fixes made to the application’s controllers
in August 2024, focusing on resolving routing issues and improving error
handling.</p>
<h2 id="issues-fixed">Issues Fixed</h2>
<h3 id="proxymanager-and-hosting-controller-loading">1. ProxyManager and
Hosting Controller Loading</h3>
<p>The ProxyManager and Hosting controllers were not being explicitly
loaded in the application, causing “Page Not Found” errors when
accessing these controllers.</p>
<p><strong>Solution:</strong> - Added explicit loading of these
controllers in <code>Comserv.pm</code>:
<code>perl   use Comserv::Controller::ProxyManager;   use Comserv::Controller::Hosting;</code></p>
<h3 id="case-sensitive-routing">2. Case-Sensitive Routing</h3>
<p>The application was using case-sensitive routes, causing issues when
users accessed URLs with different capitalization (e.g.,
<code>/ProxyManager</code> vs. <code>/proxymanager</code>).</p>
<p><strong>Solution:</strong> - Added case-insensitive route handlers in
the Root controller: ```perl # Handle lowercase version sub proxymanager
:Path(‘proxymanager’) :Args(0) { … }</p>
<p># Handle uppercase version sub ProxyManager :Path(‘ProxyManager’)
:Args(0) { … } ```</p>
<h3 id="error-template-paths">3. Error Template Paths</h3>
<p>Error templates were not properly defined, causing template not found
errors when access was denied or pages were not found.</p>
<p><strong>Solution:</strong> - Created standardized error templates in
<code>root/CSC/error/</code>: - <code>not_found.tt</code> - For 404
errors - <code>access_denied.tt</code> - For 403 errors - Updated all
controllers to use the correct template paths</p>
<h3 id="user-role-checking">4. User Role Checking</h3>
<p>The application was using inconsistent methods for checking user
roles, causing authentication issues even when users had the correct
roles. Additionally, roles were stored as arrays in the session, but the
code was treating them as strings.</p>
<p><strong>Solution:</strong> - Implemented a custom
<code>check_user_roles</code> method in the Root controller that handles
both array and string role formats: ```perl sub check_user_roles { my
($self, $c, $role) = <span class="citation"
data-cites="_">@_</span>;</p>
<pre><code>  # First check if the user exists
  return 0 unless $self-&gt;user_exists($c);
  
  # Get roles from session
  my $roles = $c-&gt;session-&gt;{roles};
  
  # Check if the user has the admin role in the session
  if ($role eq &#39;admin&#39;) {
      # For admin role, check if user is in the admin group or has admin privileges
      return 1 if $c-&gt;session-&gt;{is_admin};
      
      # Check roles array
      if (ref($roles) eq &#39;ARRAY&#39;) {
          foreach my $user_role (@$roles) {
              return 1 if lc($user_role) eq &#39;admin&#39;;
          }
      }
      # Check roles string
      elsif (defined $roles &amp;&amp; !ref($roles)) {
          return 1 if $roles =~ /\badmin\b/i;
      }
      
      # Check user_groups
      my $user_groups = $c-&gt;session-&gt;{user_groups};
      if (ref($user_groups) eq &#39;ARRAY&#39;) {
          foreach my $group (@$user_groups) {
              return 1 if lc($group) eq &#39;admin&#39;;
          }
      }
      elsif (defined $user_groups &amp;&amp; !ref($user_groups)) {
          return 1 if $user_groups =~ /\badmin\b/i;
      }
  }
  
  # For other roles, check if the role is in the user&#39;s roles
  if (ref($roles) eq &#39;ARRAY&#39;) {
      foreach my $user_role (@$roles) {
          return 1 if lc($user_role) eq lc($role);
      }
  }
  elsif (defined $roles &amp;&amp; !ref($roles)) {
      return 1 if $roles =~ /\b$role\b/i;
  }
  
  # Role not found
  return 0;</code></pre>
<p>}
<code>- Updated controllers to use this method for role checking:</code>perl
my $root_controller = <span
class="math inline"><em>c</em>− &gt; <em>c</em><em>o</em><em>n</em><em>t</em><em>r</em><em>o</em><em>l</em><em>l</em><em>e</em><em>r</em>(<sup>′</sup><em>R</em><em>o</em><em>o</em><em>t</em><sup>′</sup>); <em>u</em><em>n</em><em>l</em><em>e</em><em>s</em><em>s</em>(</span>root_controller-&gt;user_exists($c)
&amp;&amp; <span
class="math inline"><em>r</em><em>o</em><em>o</em><em>t</em><sub><em>c</em></sub><em>o</em><em>n</em><em>t</em><em>r</em><em>o</em><em>l</em><em>l</em><em>e</em><em>r</em>− &gt; <em>c</em><em>h</em><em>e</em><em>c</em><em>k</em><sub><em>u</em></sub><em>s</em><em>e</em><em>r</em><sub><em>r</em></sub><em>o</em><em>l</em><em>e</em><em>s</em>(</span>c,
‘admin’)) { # Handle unauthorized access }
<code>- Added improved logging for debugging role-based access issues:</code>perl
# Format roles for logging my $roles_debug = ‘none’; if (defined <span
class="math inline">$c-&gt;session-&gt;{roles}) {
      if (ref($</span>c-&gt;session-&gt;{roles}) eq ‘ARRAY’) { <span
class="math inline">$roles_debug = join(', ',
@{$</span>c-&gt;session-&gt;{roles}}); } else { $roles_debug =
$c-&gt;session-&gt;{roles}; } }</p>
<p><span
class="math inline"><em>s</em><em>e</em><em>l</em><em>f</em>− &gt; <em>l</em><em>o</em><em>g</em><em>g</em><em>i</em><em>n</em><em>g</em>− &gt; <em>l</em><em>o</em><em>g</em><sub><em>w</em></sub><em>i</em><em>t</em><em>h</em><sub><em>d</em></sub><em>e</em><em>t</em><em>a</em><em>i</em><em>l</em><em>s</em>(</span>c,
‘warn’, <strong>FILE</strong>, <strong>LINE</strong>, ‘index’,
“Unauthorized access attempt. User:” . ($c-&gt;session-&gt;{username} ||
‘none’) . “, Roles:” . $roles_debug); ```</p>
<h3 id="environment-specific-npm-configuration">5. Environment-Specific
NPM Configuration</h3>
<p>Implemented environment-specific configuration for NPM API keys and
settings: - Added configuration files for different environments
(production, staging, development) - Updated controllers to load
configuration from these files - Added access scope restrictions based
on environment</p>
<h2 id="configuration-files">Configuration Files</h2>
<p>The following configuration files were created or updated: -
<code>/config/npm-production.conf</code> -
<code>/config/npm-staging.conf</code> -
<code>/config/npm-development.conf</code></p>
<p>Each file follows this format:</p>
<pre><code>&lt;NPM&gt;
  api_key = &quot;npm_yourgeneratedkey123_1234567890&quot;
  endpoint = &quot;http://npm-host:81&quot;
  environment = &quot;production&quot;  # or &quot;staging&quot;/&quot;development&quot;
  access_scope = &quot;full&quot;       # or &quot;read-only&quot;/&quot;localhost-only&quot;
&lt;/NPM&gt;</code></pre>
<h2 id="controllers-updated">Controllers Updated</h2>
<ol type="1">
<li><strong>ProxyManager.pm</strong>
<ul>
<li>Added environment-specific configuration loading</li>
<li>Implemented access scope restrictions</li>
<li>Updated error template paths</li>
</ul></li>
<li><strong>Hosting.pm</strong>
<ul>
<li>Added environment-specific configuration loading</li>
<li>Implemented access scope restrictions</li>
<li>Updated error template paths</li>
</ul></li>
<li><strong>Root.pm</strong>
<ul>
<li>Added case-insensitive route handlers</li>
<li>Added default action for 404 errors</li>
<li>Added forwarding methods for ProxyManager and Hosting
controllers</li>
</ul></li>
</ol>
<h2 id="testing">Testing</h2>
<p>The changes have been tested in the following scenarios: - Accessing
<code>/proxymanager</code> and <code>/ProxyManager</code> (both should
work) - Accessing <code>/hosting</code> and <code>/Hosting</code> (both
should work) - Testing access restrictions based on environment settings
- Verifying error pages display correctly</p>
<h2 id="remote-access-improvements">Remote Access Improvements</h2>
<h3 id="allowing-admin-access-from-remote-locations">1. Allowing Admin
Access from Remote Locations</h3>
<p>The application previously restricted access to the ProxyManager and
Hosting controllers to localhost only, which prevented legitimate admin
users from accessing these features remotely.</p>
<p><strong>Solution:</strong> - Modified the localhost-only restriction
to allow admin users to access from any location - Added support for
private network ranges (192.168.x.x, 10.x.x.x, 172.16-31.x.x) -
Implemented security warnings for users accessing from remote locations
- Enhanced logging for remote access attempts</p>
<p><strong>Code Changes:</strong></p>
<div class="sourceCode" id="cb3"><pre
class="sourceCode perl"><code class="sourceCode perl"><span id="cb3-1"><a href="#cb3-1" aria-hidden="true" tabindex="-1"></a><span class="co"># Check if this is a localhost-only environment and we&#39;re not on localhost or private network</span></span>
<span id="cb3-2"><a href="#cb3-2" aria-hidden="true" tabindex="-1"></a><span class="co"># But allow admin users to access from anywhere</span></span>
<span id="cb3-3"><a href="#cb3-3" aria-hidden="true" tabindex="-1"></a><span class="cf">if</span> (<span class="dt">$self</span>-&gt;<span class="dt">npm_api</span>-&gt;{access_scope} <span class="ot">eq</span> <span class="ot">&#39;</span><span class="ss">localhost-only</span><span class="ot">&#39;</span> &amp;&amp; </span>
<span id="cb3-4"><a href="#cb3-4" aria-hidden="true" tabindex="-1"></a>    <span class="dt">$c</span>-&gt;<span class="dt">req</span>-&gt;<span class="dt">address</span> !~ <span class="ot">/</span><span class="ch">^</span><span class="ot">127\.0\.0\.1</span><span class="ch">$|^</span><span class="ot">::1</span><span class="ch">$|^</span><span class="ot">192\.168\.</span><span class="ch">|^</span><span class="ot">10\.</span><span class="ch">|^</span><span class="ot">172\.</span><span class="ch">(</span><span class="ot">1</span><span class="ch">[</span><span class="bn">6-9</span><span class="ch">]|</span><span class="ot">2</span><span class="ch">[</span><span class="bn">0-9</span><span class="ch">]|</span><span class="ot">3</span><span class="ch">[</span><span class="bn">0-1</span><span class="ch">])</span><span class="ot">\./</span>) {</span>
<span id="cb3-5"><a href="#cb3-5" aria-hidden="true" tabindex="-1"></a>    </span>
<span id="cb3-6"><a href="#cb3-6" aria-hidden="true" tabindex="-1"></a>    <span class="co"># Log the access attempt</span></span>
<span id="cb3-7"><a href="#cb3-7" aria-hidden="true" tabindex="-1"></a>    <span class="dt">$self</span>-&gt;<span class="dt">logging</span>-&gt;<span class="dt">log_with_details</span>(<span class="dt">$c</span>, <span class="ot">&#39;</span><span class="ss">info</span><span class="ot">&#39;</span>, <span class="kw">__FILE__</span>, <span class="kw">__LINE__</span>, <span class="ot">&#39;</span><span class="ss">index</span><span class="ot">&#39;</span>,</span>
<span id="cb3-8"><a href="#cb3-8" aria-hidden="true" tabindex="-1"></a>        <span class="ot">&quot;</span><span class="st">Remote access to ProxyManager from IP: </span><span class="ot">&quot;</span> . <span class="dt">$c</span>-&gt;<span class="dt">req</span>-&gt;<span class="dt">address</span> . </span>
<span id="cb3-9"><a href="#cb3-9" aria-hidden="true" tabindex="-1"></a>        <span class="ot">&quot;</span><span class="st"> by user: </span><span class="ot">&quot;</span> . (<span class="dt">$c</span>-&gt;<span class="dt">session</span>-&gt;{username} || <span class="ot">&#39;</span><span class="ss">none</span><span class="ot">&#39;</span>));</span>
<span id="cb3-10"><a href="#cb3-10" aria-hidden="true" tabindex="-1"></a>    </span>
<span id="cb3-11"><a href="#cb3-11" aria-hidden="true" tabindex="-1"></a>    <span class="co"># For security, add a warning in the stash that will be displayed to the user</span></span>
<span id="cb3-12"><a href="#cb3-12" aria-hidden="true" tabindex="-1"></a>    <span class="dt">$c</span>-&gt;<span class="dt">stash</span>-&gt;{security_warning} = <span class="ot">&quot;</span><span class="st">You are accessing this page from a remote location (</span><span class="ot">&quot;</span> . </span>
<span id="cb3-13"><a href="#cb3-13" aria-hidden="true" tabindex="-1"></a>        <span class="dt">$c</span>-&gt;<span class="dt">req</span>-&gt;<span class="dt">address</span> . <span class="ot">&quot;</span><span class="st">). For security reasons, some operations may be restricted.</span><span class="ot">&quot;</span>;</span>
<span id="cb3-14"><a href="#cb3-14" aria-hidden="true" tabindex="-1"></a>}</span></code></pre></div>
<h2 id="future-improvements">Future Improvements</h2>
<ol type="1">
<li><strong>URL Normalization</strong>
<ul>
<li>Consider implementing a URL normalization middleware to handle case
sensitivity globally</li>
</ul></li>
<li><strong>Template Organization</strong>
<ul>
<li>Reorganize templates into a more structured hierarchy (e.g.,
<code>/templates/errors/</code>, <code>/templates/admin/</code>,
etc.)</li>
</ul></li>
<li><strong>Configuration Management</strong>
<ul>
<li>Implement a more robust configuration management system for
environment-specific settings</li>
</ul></li>
<li><strong>Remote Access Security</strong>
<ul>
<li>Consider implementing additional security measures for remote admin
access:
<ul>
<li>Two-factor authentication for admin users</li>
<li>IP whitelisting configuration</li>
<li>Rate limiting for failed authentication attempts</li>
</ul></li>
</ul></li>
</ol>

</div>
