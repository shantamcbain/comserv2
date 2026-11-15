use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use_ok('Comserv::Util::Git') or BAIL_OUT('Cannot load Comserv::Util::Git');
use_ok('Comserv::Controller::Admin::Git') or BAIL_OUT('Cannot load Admin::Git');

package TLog;
sub new { bless {}, shift }
sub log_with_details { 1 }

package TReq;
sub new { my ($class, $target) = @_; bless { target => $target }, $class }
sub param {
    my ($self, $name) = @_;
    return $self->{target} if $name eq 'target';
    return;
}

package TC;
sub new { my ($class, $target) = @_; bless { req => TReq->new($target), stash => {} }, $class }
sub req    { $_[0]->{req} }
sub stash  { $_[0]->{stash} }
sub config { { git_repo_path => '/tmp/comserv-test-repo' } }

package main;

my $log = TLog->new;
my $git = Comserv::Util::Git->new(logging => $log);
my $c   = TC->new('');

my $unknown = $git->resolve_target($c, 'not-a-repo');
ok($unknown->{error}, 'unknown target is refused');
is($unknown->{repo}, undef, 'unknown target has no repo');
is($unknown->{mode}, 'unknown', 'unknown target is not local mode');
unlike($unknown->{repo} // '', qr/comserv2/, 'unknown target does not name the Comserv checkout');

my $sneaky = $git->resolve_target($c, '../etc');
ok($sneaky->{error}, 'path-like target is not a filesystem lookup');
is($sneaky->{repo}, undef, 'path-like target has no repo');

my $android = $git->resolve_target($c, 'android');
ok(!$android->{error}, 'registered external repo is allowed') or diag($android->{error});
is($android->{external}, 1, 'android is an external repo');
is($android->{repo}, '/home/shanta/.comserv/worktrees/comserv-inventory-android',
    'android resolves to its registered checkout, not Comserv');

my $local = $git->resolve_target($c, 'local');
ok(!$local->{error}, 'local is allowed');
ok(!$local->{external}, 'local is not an external repo');

my $ctl = Comserv::Controller::Admin::Git->new;
$ctl->{_git_service} = $git;

my $bad = TC->new('not-a-repo');
my $err = $ctl->_suggest_target_error($bad);
like($err, qr/Unknown git target/, 'suggest refuses an unknown target');
is($bad->stash->{git_target}, 'not-a-repo', 'refused target is still recorded');

my $ext = TC->new('android');
is($ctl->_suggest_target_error($ext), '', 'suggest accepts a registered external repo');
is($ext->stash->{git_target}, 'android', 'suggest binds the external key for later git ops');

my $home = TC->new('');
is($ctl->_suggest_target_error($home), '', 'suggest accepts the default checkout');

done_testing();
