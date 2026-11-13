use strict;
use warnings;
use Test::More;
use lib 'lib';
use Comserv::Util::FreshnessAudit;

my $fa = 'Comserv::Util::FreshnessAudit';

# --- status normaliser: every raw value seen in the live table ---------------
my %expect = (
    '1' => 1, '2' => 2, '3' => 3, '4' => 4, '5' => 5,
    'New' => 1, 'NEW' => 1, 'open' => 1, 'Task' => 1, 'Requested' => 1, 'Not-Started' => 3 - 2,
    'Pending' => 2, 'IN PROGRESS' => 2, 'In-Process' => 2,
    'completed' => 3, 'Done' => 3,
    'Cancelled' => 4, 'canceled' => 4,
);
for my $raw (sort keys %expect) {
    is $fa->normalize_status($raw)->{code}, $expect{$raw}, "status '$raw' maps to $expect{$raw}";
}
is $fa->normalize_status('2')->{canonical}, 1, 'a numeric status is already canonical';
is $fa->normalize_status('Pending')->{canonical}, 0, 'a word status needs normalising';
ok $fa->normalize_status('weird-status')->{unknown}, 'an unmapped status is reported, not guessed';
ok !defined $fa->normalize_status('weird-status')->{code}, 'unmapped status has no code';

# --- todo staleness ----------------------------------------------------------
my $today = '2026-11-09';
my $rows = [
    { record_id => 1, project_id => 100, status => '2', last_mod_date => '2026-10-09', subject => 'abandoned start' },  # 31d
    { record_id => 2, project_id => 100, status => '2', last_mod_date => '2026-10-10', subject => 'at the boundary' },   # 30d
    { record_id => 3, project_id => 100, status => '5', last_mod_date => '2026-11-08', subject => 'dangling clock' },
    { record_id => 4, project_id => 100, status => '5', last_mod_date => '2026-11-09', subject => 'open clock' },
    { record_id => 5, project_id => 100, status => 'Pending', last_mod_date => '2026-11-09', subject => 'word status' },
    { record_id => 6, project_id => 100, status => 'Task', last_mod_date => '2026-11-09', subject => 'task status' },
    { record_id => 7, project_id => 999, status => '2', last_mod_date => '2026-01-01', subject => 'other project' },
    { record_id => 8, project_id => 100, status => 'weird', last_mod_date => '2026-11-09', subject => 'unknown status' },
];
my $res = $fa->todo_staleness(
    rows       => $rows,
    open_by_id => { 4 => { start_date => '2026-11-09', start_time => '17:23:21' } },
    today      => $today,
    scope      => { project_ids => [100] },
);
my %by_id = map { ($_->{record_id} => $_) } @{ $res->{rows} };

is $by_id{1}{action}, 'decide', '31d in progress is abandoned';
ok !$by_id{2}, 'exactly 30d in progress is not stale (boundary is > 30)';
is $by_id{3}{action}, 'close_log', 'status 5 with no clock is closed';
is $by_id{4}{action}, 'close_log_with_duration', 'status 5 with a clock needs a real end time';
is $by_id{5}{action}, 'normalize', 'a word status is normalised';
is $by_id{5}{status_raw}, 'Pending', 'the raw value is carried so the fix is unambiguous';
ok !$by_id{7}, 'a todo outside the branch scope is not reported';
is $res->{skipped_out_of_scope}, 1, 'out-of-scope rows are counted, not listed';
is $by_id{8}{action}, 'normalize', 'an unmapped status is still reported';
is $res->{counts}{findings}, 6, 'six findings in scope';

# a tighter threshold moves the boundary
my $tight = $fa->todo_staleness(rows => $rows, open_by_id => {}, today => $today,
                                stale_days => 7, scope => { project_ids => [100] });
is grep({ $_->{record_id} == 2 } @{ $tight->{rows} }), 1,
   'the same row becomes stale at 7 days, so tightening is a one-line change';

# --- project staleness -------------------------------------------------------
my $projects = [
    { id => 100, name => 'Active',   status => 'In-Process' },
    { id => 200, name => 'Finished', status => 'In-Process' },
    { id => 300, name => 'Quiet',    status => 'In-Process' },
    { id => 400, name => 'Closed',   status => 'Done' },
];
my $ptodos = [
    { project_id => 100, status => '2', last_mod_date => '2026-11-08' },
    { project_id => 200, status => '3', last_mod_date => '2026-11-01' },
    { project_id => 200, status => '4', last_mod_date => '2026-10-01' },
    { project_id => 300, status => '1', last_mod_date => '2026-08-01' },
    { project_id => 400, status => '1', last_mod_date => '2026-08-01' },
];
my $pres = $fa->project_staleness(
    projects    => $projects,
    todos       => $ptodos,
    plan_pages  => { 100 => 1, 200 => 1 },
    today       => $today,
);
my %pb = map { ($_->{project_id} . ':' . $_->{action} => $_) } @{ $pres->{rows} };
ok !$pb{'100:close_project'} && !$pb{'100:dormant'}, 'a project with a fresh todo is fine';
ok $pb{'200:close_project'}, 'every todo done or cancelled -> close the project';
ok $pb{'300:dormant'}, 'no todo activity past the threshold -> dormant';
ok $pb{'300:no_plan_page'}, 'no page carries the project id';
ok !$pb{'400:close_project'} && !$pb{'400:dormant'}, 'a closed project is not audited';

# --- git touch map -----------------------------------------------------------
my $log_text = <<'LOG';
1794300000
Comserv/root/Documentation/GitDashboard.tt
Comserv/lib/Comserv/Util/FreshnessAudit.pm

1794000000
Comserv/root/Documentation/GitDashboard.tt

1793000000
Comserv/root/Documentation/Old.tt
LOG
my $touch = $fa->git_touch_map($log_text);
is $touch->{'Comserv/root/Documentation/GitDashboard.tt'}, 1794300000,
   'newest commit wins for a path touched twice';
is $touch->{'Comserv/root/Documentation/Old.tt'}, 1793000000, 'older path keeps its own time';
ok !exists $touch->{'1794300000'}, 'the timestamp line is not stored as a path';

# --- doc freshness -----------------------------------------------------------
my $pages = [
    { path => 'Comserv/root/Documentation/Stale.tt',  project_id => 238, last_updated => '2026-08-01' },
    { path => 'Comserv/root/Documentation/Fresh.tt',  project_id => 238, last_updated => '2026-11-09' },
    { path => 'Comserv/root/Documentation/Untouched.tt', project_id => 238 },
];
use Time::Local qw(timegm);
my $now = timegm(0, 0, 12, 9, 10, 2026);               # 2026-11-09 12:00 UTC
my $doc = $fa->doc_freshness(
    pages   => $pages,
    touch   => {
        'Comserv/root/Documentation/Stale.tt' => $now - 20 * 86400,
        'Comserv/root/Documentation/Fresh.tt' => $now - 1 * 86400,
    },
    project_last_change => { 238 => $now },
    stale_days => 14,
);
my %doc_action = map { ($_->{doc} . ':' . $_->{action} => 1) } @{ $doc->{rows} };
ok $doc_action{'Comserv/root/Documentation/Stale.tt:fix_meta'},
   'a page whose META date predates its own commit is flagged';
ok $doc_action{'Comserv/root/Documentation/Stale.tt:update_plan'},
   'a plan behind its project rows by more than the threshold is flagged';
ok !$doc_action{'Comserv/root/Documentation/Fresh.tt:fix_meta'},
   'a page committed after its claimed date is not flagged';
ok !$doc_action{'Comserv/root/Documentation/Untouched.tt:update_plan'},
   'a page with no commit in the window is not judged';

# --- undocumented surfaces ---------------------------------------------------
my $undoc = $fa->undocumented_surfaces(
    changed_paths => [
        'Comserv/lib/Comserv/Util/BrandNewThing.pm',
        'Comserv/lib/Comserv/Controller/Git.pm',
        'Comserv/lib/Comserv/Util/BrandNewThing.pm',
        'Comserv/root/static/js/git-dashboard.js',
    ],
    pages => [ { path => 'Comserv/root/Documentation/GitDashboard.tt' } ],
);
my @surfaces = map { $_->{surface} } @{ $undoc->{rows} };
is scalar @surfaces, 1, 'one undocumented surface, deduped';
like $surfaces[0], qr/BrandNewThing\.pm$/, 'the undocumented one is named';

# --- composition and the audit-todo plan -------------------------------------
my $composed = $fa->collect(
    branch   => 'main',
    scope    => { project_ids => [100] },
    todos    => $rows,
    projects => $projects,
    open_by_id => { 4 => { start_date => '2026-11-09', start_time => '17:23:21' } },
    pages    => [ { path => 'Comserv/root/Documentation/Stale.tt', project_id => 238,
                    last_updated => '2026-08-01' } ],
    plan_pages   => { 238 => 1 },
    touch        => { 'Comserv/root/Documentation/Stale.tt' => timegm(0, 0, 12, 9, 10, 2026) - 20 * 86400 },
    project_last_change => { 238 => timegm(0, 0, 12, 9, 10, 2026) },
    changed_paths => [ 'Comserv/lib/Comserv/Util/BrandNewThing.pm' ],
    today      => '2026-11-09',
);
is $composed->{branch}, 'main', 'the composed report is branch-stamped';
ok $composed->{totals}{findings} > 0, 'the composed report carries a total';
is $composed->{counts}{findings}, $composed->{totals}{findings},
   'the merged findings count is the sum of the sections';
is $composed->{counts}{findings}, $composed->{todos}{counts}{findings}
   + $composed->{projects}{counts}{findings} + $composed->{docs}{counts}{findings}
   + $composed->{undocumented}{counts}{findings}, 'and it equals the four sections';
ok exists $composed->{counts}{undocumented}, 'doc-surface findings are counted';

my $plan = $fa->audit_todo_plan($composed);
is scalar @$plan, 3, 'one audit todo per group when nothing declares ownership';
my ($todo_plan) = grep { $_->{group} eq 'todos' } @$plan;
is $todo_plan->{subject}, 'Stale todos on main', 'the subject names the branch';
unlike join(' ', map { $_->{subject} } @$plan), qr/\d/,
   'subjects carry no counts, so a moving count cannot file a new todo every run';
like $todo_plan->{description}, qr/\[decide\] todo 1:/, 'the body lists the findings';
like $todo_plan->{description}, qr/findings as of 2026-11-09/, 'the body carries the count and date';
is scalar @{ $fa->audit_todo_plan({ branch => 'main', todos => { counts => { findings => 0 } },
                                    projects => { counts => { findings => 0 } },
                                    docs => { counts => { findings => 0 } },
                                    undocumented => { counts => { findings => 0 } } }) },
   0, 'no findings means no audit todos';

# --- routing: each finding goes to the branch that owns it -------------------
my $routed = $fa->route_findings(
    $composed,
    owner_map => { 100 => { branch => 'git',    project_id => 238 },
                   238 => { branch => 'schema', project_id => 5 },
                   300 => { branch => '3d',     project_id => 272 } },
    fallback  => { branch => 'main', project_id => 311 },
);
my %route = map { ($_->{branch} . '/' . $_->{group} => $_) } @$routed;
ok $route{'git/todos'},       'todo findings are filed to the owning branch';
is $route{'git/todos'}{project_id}, 238, 'and carry that branch project id';
ok $route{'3d/projects'},     'project findings are filed to their owner too';
is $route{'3d/projects'}{project_id}, 272, 'with the owner project id';
ok $route{'schema/docs'},     'doc findings follow the page project_id';
is $route{'schema/docs'}{project_id}, 5, 'schema page -> schema project';
ok $route{'main/docs'},       'an undocumented code surface stays with the trunk';
is $route{'main/docs'}{project_id}, 311, 'filed under Release Engineering';
ok $route{'main/projects'},   'an unowned project stays with the trunk';

# the audit's own todos are never counted as stale work
my $own = $fa->todo_staleness(
    rows => [ { record_id => 9, project_id => 100, status => '2',
                last_mod_date => '2026-01-01',
                subject => 'Stale todos on main: 5 need a decision' } ],
    today => $today, scope => { project_ids => [100] },
);
is scalar @{ $own->{rows} }, 0, 'the audit does not audit itself';

# the integration branch is declared responsible for every project
my $agg = $fa->todo_staleness(
    rows  => [ { record_id => 7, project_id => 999, status => '2',
                 last_mod_date => '2026-01-01', subject => 'someone else\'s todo' } ],
    today => $today,
    scope => { project_ids => [], declared => 1, aggregate => 1 },
);
is scalar @{ $agg->{rows} }, 1, 'aggregate scope (main) covers every project';
is $agg->{skipped_out_of_scope}, 0, 'and skips nothing';

done_testing;
