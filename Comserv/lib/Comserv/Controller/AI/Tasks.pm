package Comserv::Controller::AI::Tasks;

# /ai/tasks - Hermes tasks with Done / Partial / Failed rating (eval #33) and
# the commit-time code reviewer (eval #34-#35). Admin only; POSTs need the
# same CSRF token as /ai/eval (guards reused from Controller::AI::Eval).

use Moose;
use namespace::autoclean -except => [qw(try catch finally)];
use Try::Tiny;
use JSON ();
use Comserv::Util::Logging;
use Comserv::Model::AI2::TaskTracker;
use Comserv::Util::AI::CodeReviewer;
BEGIN { extends 'Catalyst::Controller' }
__PACKAGE__->config(namespace => 'ai/tasks');

has 'logging' => (is => 'ro', default => sub { Comserv::Util::Logging->instance });

sub _eval    { $_[1]->controller('AI::Eval') }
sub _root    { my ($self, $c) = @_; my $r = '' . $c->path_to(''); $r =~ s{/$}{}; $r }
sub _tracker { my ($self, $c) = @_; Comserv::Model::AI2::TaskTracker->new(root => $self->_root($c)) }
sub _reviewer{ my ($self, $c) = @_; Comserv::Util::AI::CodeReviewer->new(root => $self->_root($c)) }
sub _last_file { my ($self, $c) = @_; $self->_root($c) . '/data/ai_reviewer_last.json' }

sub _save_last {
    my ($self, $c, $res) = @_;
    my $f = $self->_last_file($c);
    my $list = eval { open my $fh, '<', $f or die; local $/; JSON->new->decode(<$fh>) } || [];
    unshift @$list, { %$res, at => time, at_pt => Comserv::Model::AI2::TaskTracker::_pt(time), by => $self->_eval($c)->_username($c) };
    splice @$list, 20 if @$list > 20;
    if (open my $fh, '>', "$f.tmp") { print $fh JSON->new->canonical->pretty->encode($list); close $fh; rename "$f.tmp", $f }
    return $list;
}

sub index :Path :Args(0) {
    my ($self, $c) = @_;
    my $ev = $self->_eval($c);
    return unless $ev->_require_admin($c);
    my $days = ($c->req->params->{days} // '') =~ /^(\d{1,2})$/ ? $1 : 14;
    my $data = eval { $self->_tracker($c)->build(days => $days, force => ($c->req->params->{refresh} ? 1 : 0)) } || { error => "$@", tasks => [] };
    my $rv = $self->_reviewer($c);
    my ($spent, $calls) = $rv->spent_today;
    my $last = eval { open my $fh, '<', $self->_last_file($c) or die; local $/; JSON->new->decode(<$fh>) } || [];
    my $only = $c->req->params->{show} // '';
    my @tasks = @{ $data->{tasks} || [] };
    @tasks = grep { !$_->{rating} } @tasks if $only eq 'unrated';
    @tasks = grep { $_->{corrections} || @{ $_->{rewritten} || [] } } @tasks if $only eq 'flagged';
    $c->stash(
        template   => 'ai/tasks.tt',
        page_title => 'AI tasks and code reviewer',
        tasks      => $data,
        task_list  => \@tasks,
        show       => $only,
        days       => $days,
        csrf_token => $ev->_csrf_token($c),
        reviewer   => { cfg => $rv->config, spent_today => $spent, calls_today => $calls, last => $last },
        ai_eval_msg => delete $c->flash->{ai_eval_msg},
        ai_eval_err => delete $c->flash->{ai_eval_err},
    );
}

sub rate :Local :Args(0) {
    my ($self, $c) = @_;
    my $ev = $self->_eval($c);
    my $back = $c->uri_for('/ai/tasks', { show => ($c->req->body_params->{show} // '') });
    return unless $ev->_post_guard($c, $back);
    my $p = $c->req->body_params;
    my $err = $self->_tracker($c)->rate($p->{task_id}, $p->{rating}, note => $p->{note}, by => $ev->_username($c));
    if ($err) { $c->flash->{ai_eval_err} = "Rating not saved: $err" }
    else      { $c->flash->{ai_eval_msg} = "Saved: $p->{rating}" }
    $c->response->redirect($back . '#t-' . ($p->{anchor} // ''));
}

# One small live check of the reviewer (a few cents at most).
sub review_test :Local :Args(0) {
    my ($self, $c) = @_;
    my $ev = $self->_eval($c);
    my $back = $c->uri_for('/ai/tasks') . '#reviewer';
    return unless $ev->_post_guard($c, $back);
    my $diff = <<'DIFF';
--- a/lib/Comserv/Model/Example.pm
+++ b/lib/Comserv/Model/Example.pm
@@ -10,6 +10,12 @@ sub find_user {
     my ($self, $c, $name) = @_;
-    return $self->schema->resultset('User')->find({ username => $name });
+    my $dbh = $self->schema->storage->dbh;
+    my $row = $dbh->selectrow_hashref("SELECT * FROM users WHERE username = '$name'");
+    try {
+        return $row if $row;
+    } catch { };
+    return undef;
DIFF
    my $res = $self->_reviewer($c)->review($c, diff => $diff, author_models => [], task => 'Reviewer self-test (known bugs: SQL injection, raw SQL, Try::Tiny return).', source => 'self_test');
    $self->_save_last($c, { %$res, source => 'self_test' });
    $c->flash->{ $res->{ok} ? 'ai_eval_msg' : 'ai_eval_err' } = $res->{ok}
        ? sprintf('Reviewer test OK: %s, $%.4f (today $%.4f of $%.2f).', $res->{model}, $res->{usd}, $res->{spent_today}, $res->{cap})
        : 'Reviewer test did not run: ' . ($res->{reason} // '?');
    $c->response->redirect($back);
}

# Commit-time gate hook (warn only). Reviews `git diff --cached` of this app's
# repo. POST JSON (X-CSRF-Token header). Ready for the AI Editor commit form;
# wiring into Admin/Git.pm / admin/git/index.tt waits until those staged files
# are released.
sub review_staged :Local :Args(0) {
    my ($self, $c) = @_;
    my $ev = $self->_eval($c);
    return $ev->_json_out($c, 403, { ok => 0, error => 'admin only' }) unless $ev->_is_admin($c);
    return $ev->_json_out($c, 405, { ok => 0, error => 'POST only' }) unless $c->req->method eq 'POST';
    return $ev->_json_out($c, 403, { ok => 0, error => 'csrf' }) unless $ev->_csrf_ok($c);
    my $root = $self->_root($c);
    my ($diff, @paths) = ('');
    if (open my $fh, '-|', 'git', '-C', $root, 'diff', '--cached', '--no-color', '--', '.') { local $/; $diff = <$fh> // ''; close $fh }
    if (open my $fh, '-|', 'git', '-C', $root, 'diff', '--cached', '--name-only', '--', '.') { chomp(@paths = <$fh>); close $fh }
    my $author = eval { $self->_tracker($c)->author_for_paths(@paths) };
    my @am = $author ? @{ $author->{models} || [] } : ();
    push @am, split /\s*,\s*/, ($c->req->body_params->{author_model} // '');
    my $res = $self->_reviewer($c)->review($c, diff => $diff, author_models => [ grep { length } @am ],
        task => ($author ? join("\n", @{ $author->{prompts} || [] }[0..1]) : undef), source => 'commit_gate');
    $res->{files} = \@paths;
    $res->{author_task} = $author ? $author->{id} : undef;
    $res->{blocking} = 0;   # warn mode only
    $self->_save_last($c, { %$res, source => 'commit_gate' });
    return $ev->_json_out($c, 200, $res);
}

__PACKAGE__->meta->make_immutable;
1;
