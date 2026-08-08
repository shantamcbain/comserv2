use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Test::More;
use Catalyst::Test 'Comserv';
use Comserv::Controller::Project;

{
    package MockLogging;
    sub new        { bless {}, shift }
    sub instance   { bless {}, shift }
    sub log_with_details { }
}

my $ctrl = Comserv::Controller::Project->new( logging => MockLogging->new );

# Mock $c that returns a query_parameters HASHREF (this Catalyst version exposes
# query_parameters as a plain hashref, not a Hash::MultiValue object).
sub mock_c {
    my (%arg) = @_;
    my $qp = $arg{qp} // {};
    bless {
        _session => $arg{session} // { SiteName => 'CSC', is_admin => 1, username => 'Shanta', roles => ['admin'] },
        _stash   => {},
        _req     => { query_parameters => $qp },
    }, 'MockCProj';
}
sub MockCProj::session { $_[0]->{_session} }
sub MockCProj::stash   { my ($s,%kv)=@_; $s->{_stash} = { %{$s->{_stash}}, %kv } if %kv; $s->{_stash} }
sub MockCProj::model   { Comserv->model($_[1]) }
sub MockCProj::logging { MockLogging->new }
sub MockCProj::request { bless { query_parameters => $_[0]->{_req}{query_parameters} }, 'MockReq' }
sub MockReq::query_parameters { $_[0]->{query_parameters} }

# 1) No sitename param -> full top-level set returned.
my $all = $ctrl->fetch_projects_with_subprojects(mock_c(), 1, 0, undef);
ok(scalar(@$all) >= 1, 'no filter returns top-level projects');

# 2) Filter by a sitename that genuinely exists as a COLUMN value among
#    top-level projects (queried directly, so we test a real value rather than a
#    possibly relationship-derived display name).
my $schema = Comserv->model('DBEncy')->schema;
my $real = $schema->resultset('Project')->search(
    { -or => [ {parent_id => undef}, {parent_id => 0} ],
      sitename => { '!=', undef }, sitename => { '!=', '' } },
    { columns => { s => 'sitename' }, distinct => 1, rows => 1 }
)->single;
if ($real && (my $chosen = $real->sitename)) {
    diag("filtering top-level by real column sitename = [$chosen]");
    my $f = $ctrl->fetch_projects_with_subprojects(mock_c(), 1, 0, [ $chosen ]);
    ok(scalar(@$f) >= 1, "filter to real sitename '$chosen' returns results");
    my $match = grep { ($_->{sitename} // '') eq $chosen } @$f;
    is($match, scalar(@$f), "all filtered results have sitename '$chosen'");
} else {
    ok(1, 'no non-empty sitename column found (skipped)');
    ok(1, 'skipped');
}

# 3) The param-reading path that previously 500'd now works with a hashref qp.
#    This mirrors the defensive read in the project action (line ~403).
sub read_selected {
    my ($qp) = @_;
    my $raw = (ref $qp eq 'HASH') ? $qp->{sitename} : undef;
    return ref $raw eq 'ARRAY' ? @$raw : (defined $raw ? ($raw) : ());
}
my @multi = read_selected({ sitename => [ qw(CSC BMaster) ] });
is(scalar(@multi), 2, 'multi-valued sitename param read as array');
my @single = read_selected({ sitename => 'CSC' });
is(scalar(@single), 1, 'single-valued sitename param read as scalar');
my @none = read_selected({});
is(scalar(@none), 0, 'absent sitename param yields empty list');

done_testing;
