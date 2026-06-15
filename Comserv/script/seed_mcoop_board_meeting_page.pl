#!/usr/bin/env perl
# Seed Monashee Co-op board meeting overview into the page table.
# Run: perl script/seed_mcoop_board_meeting_page.pl [--update]
use strict;
use warnings;
use lib 'lib';
use Catalyst::Test 'Comserv';
use Getopt::Long qw(GetOptions);

my $update   = 0;
my $sitename = 'MCoop';
GetOptions('update' => \$update, 'sitename=s' => \$sitename)
    or die "Usage: $0 [--update] [--sitename MCoop]\n";

my $body = do { local $/; <DATA> };
$body =~ s/^\n//;

my %page = (
    sitename    => $sitename,
    menu        => 'Admin',
    page_code   => 'board_meeting',
    title       => 'Board & IT Meeting - Platform Overview',
    body        => $body,
    description => 'How the Monashee Co-op application supports every organizational level.',
    keywords    => 'Monashee Coop, board, roles, workshops, accounting, marketplace, newsletter',
    link_order  => 5,
    status      => 'active',
    roles       => 'admin',
    page_type   => 'standard',
    created_by  => 'seed_script',
);

my $schema = Comserv->model('DBEncy');
my $rs     = $schema->resultset('Page');

my $existing = $rs->search(
    { sitename => $sitename, page_code => $page{page_code} },
    { rows => 1 }
)->single;

if ($existing) {
    if ($update) {
        $existing->update({
            map { $_ => $page{$_} } grep { $_ ne 'created_by' } keys %page
        });
        print "Updated page id=" . $existing->id . "\n";
    } else {
        print "Page already exists (id=" . $existing->id . "). Use --update to refresh.\n";
        exit 0;
    }
} else {
    my $row = $rs->create(\%page);
    print "Created page id=" . $row->id . "\n";
}

print "View at: /page/board_meeting (MCoop admin)\n";
exit 0;

__DATA__
<style>
.bm-page { font-family: var(--body-font, Verdana, Helvetica, sans-serif); color: var(--text-color, #333); line-height: 1.6; max-width: 1100px; margin: 0 auto; }
.bm-hero { background: linear-gradient(135deg, var(--primary-color, #FF6600) 0%, var(--accent-color, #FF9933) 100%); color: #fff; padding: 2rem 2.5rem; border-radius: 8px; margin-bottom: 2rem; }
.bm-hero h1 { margin: 0 0 0.5rem; font-family: var(--header-font, Verdana, sans-serif); font-size: var(--font-size-xlarge, 1.75rem); color: #fff; border: none; }
.bm-hero .bm-subtitle { font-size: var(--font-size-large, 1.15rem); opacity: 0.95; margin: 0 0 1rem; }
.bm-hero .bm-meta { font-size: var(--font-size-small, 0.9rem); opacity: 0.85; }
.bm-tagline { font-style: italic; border-left: 4px solid var(--accent-color, #FF6600); padding: 0.75rem 1.25rem; margin: 1.5rem 0; background: var(--secondary-color, #f9f9f9); border-radius: 0 6px 6px 0; }
.bm-section { margin-bottom: 2.5rem; }
.bm-section h2 { color: var(--primary-color, #FF6600); font-family: var(--header-font); border-bottom: 2px solid var(--border-color, #ddd); padding-bottom: 0.4rem; margin-top: 0; }
.bm-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 1.25rem; margin-top: 1rem; }
.bm-card { background: #fff; border: 1px solid var(--border-color, #ddd); border-radius: 8px; padding: 1.25rem; box-shadow: 0 2px 4px rgba(0,0,0,0.06); }
.bm-card h3 { margin-top: 0; font-size: 1.1rem; color: var(--primary-color, #FF6600); }
.bm-card ul { margin: 0.5rem 0 0; padding-left: 1.25rem; }
.bm-feature-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 1rem; margin-top: 1rem; }
.bm-feature { background: var(--secondary-color, #f9f9f9); border-radius: 8px; padding: 1.25rem; border-left: 4px solid var(--primary-color, #FF6600); }
.bm-feature h4 { margin: 0 0 0.5rem; }
.bm-feature p { margin: 0; font-size: var(--font-size-small, 0.95rem); }
.bm-table { width: 100%; border-collapse: collapse; font-size: var(--font-size-small, 0.95rem); }
.bm-table th, .bm-table td { border: 1px solid var(--border-color, #ddd); padding: 0.6rem 0.75rem; text-align: left; vertical-align: top; }
.bm-table th { background: var(--table-header-bg, #f2f2f2); }
.bm-table tr:nth-child(even) { background: var(--secondary-color, #fafafa); }
.bm-yes { color: var(--success-color, #339933); font-weight: bold; }
.bm-partial { color: var(--accent-color, #FF9900); }
.bm-security { background: #f0f7ff; border: 1px solid #b8d4f0; border-radius: 8px; padding: 1.5rem; }
.bm-flow { display: flex; flex-wrap: wrap; gap: 0.5rem; align-items: center; margin: 1rem 0; font-size: var(--font-size-small, 0.9rem); }
.bm-flow-step { background: var(--secondary-color, #f0f0f0); padding: 0.4rem 0.75rem; border-radius: 4px; border: 1px solid var(--border-color, #ccc); }
.bm-flow-arrow { color: var(--primary-color, #FF6600); font-weight: bold; }
.bm-callout { background: #fff8e6; border: 1px solid #ffd966; border-radius: 6px; padding: 1rem 1.25rem; margin-top: 1rem; }
</style>

<div class="bm-page">

<div class="bm-hero">
  <h1>Monashee Co-op Platform Overview</h1>
  <p class="bm-subtitle">How this application supports every level of the organization</p>
  <p class="bm-meta">Prepared for Board &amp; IT Staff Meeting &mdash; June 2026</p>
</div>

<p class="bm-tagline">
  &ldquo;In order to change an existing paradigm you do not struggle to try and change the problematic model.
  You create a new model and make the old one obsolete.&rdquo; &mdash; R. Buckminster Fuller
</p>

<div class="bm-section">
  <h2>Executive Summary</h2>
  <p>
    The Monashee Co-op application is a single, secure platform that serves <strong>guests, members, volunteers,
    vendors, editors, developers, and administrators</strong> &mdash; each seeing only what their role allows.
    The board controls who sees what; admins assign roles; and users may hold <strong>multiple roles at once</strong>
    (for example, a member who is also a vendor and volunteer).
  </p>
  <p>
    Built-in modules cover <strong>workshops &amp; events</strong>, <strong>easy accounting</strong>,
    <strong>marketplace accounting</strong>, and a <strong>newsletter system</strong> &mdash; giving the co-op
    modern tools without juggling separate websites, spreadsheets, and email lists.
  </p>
</div>

<div class="bm-section">
  <h2>One Platform, Role-Based Views</h2>
  <p>When someone logs in, the site adapts to their assigned roles. Navigation, pages, and tools are filtered automatically.</p>

  <div class="bm-grid">
    <div class="bm-card">
      <h3>Guest (not logged in)</h3>
      <ul>
        <li>Views all <strong>public</strong> areas of the site</li>
        <li>Gets basic answers about what the co-op offers via <strong>Chat with AI</strong></li>
        <li>Can browse public marketplace listings and workshop schedules</li>
        <li>Cannot enter private data or access member-only areas</li>
        <li>May subscribe to the public newsletter mailing list</li>
      </ul>
    </div>
    <div class="bm-card">
      <h3>Member</h3>
      <ul>
        <li>Sees additional site content as determined by the <strong>board</strong></li>
        <li>Access to member directory, member-only buy &amp; sell, and streaming tools</li>
        <li>May include a <strong>membership application form</strong> for prospective members</li>
        <li>Receives member discounts on workshops (plan-based benefits)</li>
      </ul>
    </div>
    <div class="bm-card">
      <h3>Volunteer</h3>
      <ul>
        <li>Sees volunteer-specific information and schedules</li>
        <li>Access to member areas plus volunteer coordination content</li>
        <li>Can be added to volunteer mailing lists for announcements</li>
      </ul>
    </div>
    <div class="bm-card">
      <h3>Vendor</h3>
      <ul>
        <li>Sees vendor-related information and supplier workflows</li>
        <li>Connected to <strong>accounting</strong> vendor and AP records</li>
        <li>May list products in the co-op shop and marketplace</li>
      </ul>
    </div>
    <div class="bm-card">
      <h3>Editor</h3>
      <ul>
        <li>Can <strong>edit document pages</strong> and site content</li>
        <li>Manages newsletters, mailing lists, and public-facing information</li>
        <li>Cannot change site code or assign user roles</li>
      </ul>
    </div>
    <div class="bm-card">
      <h3>Developer</h3>
      <ul>
        <li>Can change <strong>site code</strong>, templates, and technical configuration</li>
        <li>Access to documentation, deployment tools, and system diagnostics</li>
      </ul>
    </div>
    <div class="bm-card">
      <h3>Admin</h3>
      <ul>
        <li><strong>Assigns roles</strong> to members for application access</li>
        <li>Full site management: pages, users, themes, accounting, workshops</li>
        <li>Creates mailing lists for board, staff, and volunteers</li>
        <li>Exact rights for each group can be set by admin and the board</li>
      </ul>
    </div>
  </div>

  <div class="bm-callout">
    <strong>Multiple roles:</strong> A single person can hold several roles simultaneously.
    For example, a <em>member + vendor + volunteer</em> sees the combined access of all three roles.
  </div>
</div>

<div class="bm-section">
  <h2>Key Features for the Co-op</h2>
  <div class="bm-feature-grid">
    <div class="bm-feature">
      <h4>Workshops &amp; Events</h4>
      <p>Schedule workshops, manage registrations and payments, share files, send attendee emails, and track workshop leaders. Members receive plan-based discounts.</p>
    </div>
    <div class="bm-feature">
      <h4>Easy Accounting</h4>
      <p>Chart of accounts, general ledger, invoicing, and expense tracking. Enter receipts and supplier invoices without external software. GST/HST and bank reconciliation included.</p>
    </div>
    <div class="bm-feature">
      <h4>Marketplace Accounting</h4>
      <p>Cross-site marketplace connects co-op listings with broader exposure. Shop inventory pushes to marketplace; sales flow into accounting records.</p>
    </div>
    <div class="bm-feature">
      <h4>Newsletter System</h4>
      <p>Create, draft, and send newsletters to members, role-based lists, or workshop attendees. Auto-synced mailing lists for board, staff, and volunteers.</p>
    </div>
    <div class="bm-feature">
      <h4>HelpDesk System</h4>
      <p>Built-in support portal: submit tickets, track status, knowledge base, and contact forms. Guests get answers; members escalate issues; admins manage categories, staff permissions, and email templates. A key selling point for hosted sites.</p>
    </div>
    <div class="bm-feature">
      <h4>Chat with AI</h4>
      <p>Site-aware AI helps guests and members find answers and navigate features. Editors and admins can use AI to help draft and update page content.</p>
    </div>
    <div class="bm-feature">
      <h4>Page Management</h4>
      <p>Board and editors control what each audience sees. Pages are edited through Admin &rarr; Pages with role-based visibility.</p>
    </div>
  </div>
</div>

<div class="bm-section">
  <h2>HelpDesk System</h2>
  <p>
    Every site includes a full <strong>HelpDesk support portal</strong> &mdash; one of the platform&rsquo;s strongest differentiators
    for organizations that need professional support without buying separate ticketing software.
  </p>
  <div class="bm-grid">
    <div class="bm-card">
      <h3>For guests &amp; members</h3>
      <ul>
        <li>Submit support tickets with categories and attachments</li>
        <li>Check ticket status and receive email updates</li>
        <li>Browse the knowledge base and FAQs</li>
        <li>Contact form for general inquiries</li>
        <li>AI-assisted help on HelpDesk pages</li>
      </ul>
    </div>
    <div class="bm-card">
      <h3>For admins &amp; staff</h3>
      <ul>
        <li>Admin dashboard for open, resolved, and closed tickets</li>
        <li>Manage categories, KB articles, and email templates</li>
        <li>Staff permissions and role-based HelpDesk access</li>
        <li>System settings per site</li>
        <li>Integrated with site navigation (top HelpDesk menu)</li>
      </ul>
    </div>
    <div class="bm-card">
      <h3>Why it matters for the co-op</h3>
      <ul>
        <li>Members get timely answers without email chaos</li>
        <li>Board and staff see a clear audit trail of issues</li>
        <li>Included with hosting &mdash; no extra SaaS subscription</li>
        <li>Same login and roles as the rest of the platform</li>
      </ul>
    </div>
  </div>
  <div class="bm-callout">
    <strong>Demo:</strong> Visit <em>HelpDesk</em> in the top menu to see ticket submission, knowledge base, and (for admins) the HelpDesk administration panel.
  </div>
</div>

<div class="bm-section">
  <h2>Access at a Glance</h2>
  <table class="bm-table">
    <thead>
      <tr>
        <th>Capability</th><th>Guest</th><th>Member</th><th>Volunteer</th><th>Vendor</th><th>Editor</th><th>Developer</th><th>Admin</th>
      </tr>
    </thead>
    <tbody>
      <tr><td>View public pages &amp; marketplace</td><td class="bm-yes">Yes</td><td class="bm-yes">Yes</td><td class="bm-yes">Yes</td><td class="bm-yes">Yes</td><td class="bm-yes">Yes</td><td class="bm-yes">Yes</td><td class="bm-yes">Yes</td></tr>
      <tr><td>Member-only content</td><td>&mdash;</td><td class="bm-yes">Yes</td><td class="bm-yes">Yes</td><td class="bm-yes">Yes</td><td class="bm-yes">Yes</td><td class="bm-yes">Yes</td><td class="bm-yes">Yes</td></tr>
      <tr><td>Edit document pages</td><td>&mdash;</td><td>&mdash;</td><td>&mdash;</td><td>&mdash;</td><td class="bm-yes">Yes</td><td class="bm-yes">Yes</td><td class="bm-yes">Yes</td></tr>
      <tr><td>Change site code</td><td>&mdash;</td><td>&mdash;</td><td>&mdash;</td><td>&mdash;</td><td>&mdash;</td><td class="bm-yes">Yes</td><td class="bm-yes">Yes</td></tr>
      <tr><td>Assign user roles</td><td>&mdash;</td><td>&mdash;</td><td>&mdash;</td><td>&mdash;</td><td>&mdash;</td><td>&mdash;</td><td class="bm-yes">Yes</td></tr>
      <tr><td>Accounting &amp; reports</td><td>&mdash;</td><td>&mdash;</td><td>&mdash;</td><td class="bm-partial">Vendor</td><td>&mdash;</td><td class="bm-partial">Technical</td><td class="bm-yes">Yes</td></tr>
      <tr><td>Workshops</td><td class="bm-partial">Browse</td><td class="bm-yes">Register</td><td class="bm-partial">Assigned</td><td class="bm-partial">Assigned</td><td class="bm-partial">Content</td><td class="bm-yes">Yes</td><td class="bm-yes">Yes</td></tr>
      <tr><td>Newsletters</td><td class="bm-partial">Subscribe</td><td class="bm-partial">Read</td><td class="bm-partial">Lists</td><td class="bm-partial">Lists</td><td class="bm-yes">Send</td><td class="bm-yes">Yes</td><td class="bm-yes">Yes</td></tr>
      <tr><td>HelpDesk (tickets, KB)</td><td class="bm-partial">Submit</td><td class="bm-yes">Yes</td><td class="bm-yes">Yes</td><td class="bm-yes">Yes</td><td class="bm-partial">Content</td><td class="bm-yes">Yes</td><td class="bm-yes">Yes</td></tr>
    </tbody>
  </table>
</div>

<div class="bm-section bm-security">
  <h2>Security &amp; Governance</h2>
  <p>Security is built in through <strong>role-based access control</strong> and <strong>admin-managed permissions</strong>:</p>
  <ul>
    <li>Every page and feature checks the user&rsquo;s roles before granting access</li>
    <li>Admins assign roles after registration &mdash; new users start with limited access until approved</li>
    <li>Multiple roles are evaluated together using the user&rsquo;s full role set</li>
    <li>Site isolation keeps each co-op site&rsquo;s data separate unless explicitly shared</li>
    <li>Accounting and personal data restricted to authorized roles only</li>
  </ul>
  <h3>How a new user gets access</h3>
  <div class="bm-flow">
    <span class="bm-flow-step">1. Register</span><span class="bm-flow-arrow">&rarr;</span>
    <span class="bm-flow-step">2. Admin notified</span><span class="bm-flow-arrow">&rarr;</span>
    <span class="bm-flow-step">3. Board assigns role(s)</span><span class="bm-flow-arrow">&rarr;</span>
    <span class="bm-flow-step">4. Role-appropriate view</span>
  </div>
</div>

<div class="bm-section">
  <h2>What This Means for the Board</h2>
  <ul>
    <li><strong>One system</strong> replaces scattered tools for website, email, workshops, shop, and accounting</li>
    <li><strong>You control visibility</strong> &mdash; decide what each group sees without developer help for everyday content</li>
    <li><strong>Scales with the co-op</strong> &mdash; new roles, pages, and features can be added as needs evolve</li>
    <li><strong>IT staff</strong> maintain infrastructure; <strong>editors</strong> handle day-to-day content</li>
  </ul>
</div>

<div class="bm-section">
  <h2>Discussion Points for This Meeting</h2>
  <ol>
    <li>Confirm the role list and what each group should see at launch</li>
    <li>Review membership application workflow and board approval process</li>
    <li>Prioritize newsletter and mailing lists (board, staff, volunteers)</li>
    <li>Workshop schedule and registration for upcoming events</li>
    <li>Accounting setup: chart of accounts, bank accounts, and reporting needs</li>
    <li>Marketplace strategy: local shop vs. cross-site listings</li>
    <li>Timeline for moving content from the legacy site to this platform</li>
  </ol>
</div>

</div>