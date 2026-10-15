package Comserv::Model::AI2::TaskTracker;

# Hermes tasks + human ratings (Oct 12 2026, eval #33).
#   Reads ~/.hermes/state.db READ-ONLY (same access as ModelScorecard).
#   Groups sessions into tasks (Comserv::Util::AI::TaskGrouper).
#   Ratings (done / partial / failed + note) live in data/ai_task_ratings.json
#   and always override the heuristic guess.
# Cache: data/ai_tasks_cache.json, 10 min (?refresh=1 rebuilds).

use strict;
use warnings;
use DBI;
use JSON::PP ();
use POSIX qw(strftime);
use Fcntl qw(:flock);
use Comserv::Util::AI::TaskGrouper;

my $J = JSON::PP->new->canonical;
our $CACHE_TTL = 600;

sub new { my ($class, %a) = @_; return bless { %a }, $class }
sub hermes_home  { $_[0]{hermes_home} || $ENV{HERMES_HOME} || (($ENV{HOME} || '/home/shanta') . '/.hermes') }
sub root         { my $r = $_[0]{root} || '.'; $r =~ s{/$}{}; $r }
sub cache_file   { $_[0]->root . '/data/ai_tasks_cache.json' }
sub ratings_file { $_[0]->root . '/data/ai_task_ratings.json' }

sub _read_json { my ($f) = @_; open my $fh, '<', $f or return undef; local $/; my $d = eval { $J->decode(<$fh>) }; close $fh; $d }
sub _write_json {
    my ($f, $d) = @_;
    open my $fh, '>', "$f.tmp" or return "cannot write $f: $!";
    print $fh $J->pretty->encode($d); close $fh;
    rename "$f.tmp", $f or return "rename: $!";
    return undef;
}
sub _pt { local $ENV{TZ} = 'America/Vancouver'; POSIX::tzset(); my $r = strftime('%a %b %d %H:%M PT', localtime($_[0] // 0)); POSIX::tzset(); $r }

sub ratings { my ($s) = @_; return _read_json($s->ratings_file) || {} }

# rate($task_id, $rating, note => ..., by => ...) ; rating 'clear' removes it.
sub rate {
    my ($s, $id, $rating, %o) = @_;
    return 'bad task id' unless defined $id && $id =~ /^[\w.\-]+:\d+$/;
    return 'bad rating'  unless defined $rating && $rating =~ /^(done|partial|failed|clear)$/;
    my $f = $s->ratings_file;
    open my $lk, '>>', "$f.lock" or return "lock: $!";
    flock $lk, LOCK_EX;
    my $all = $s->ratings;
    if ($rating eq 'clear') { delete $all->{$id} }
    else {
        my $note = substr($o{note} // '', 0, 500);
        $all->{$id} = { rating => $rating, note => $note, by => ($o{by} // 'unknown'), at => time, at_pt => _pt(time) };
    }
    my $err = _write_json($f, $all);
    close $lk;
    return $err;
}

sub build {
    my ($s, %a) = @_;
    my $days = $a{days} || 14;
    if (!$a{force} && (my $c = _read_json($s->cache_file))) {
        return $s->_decorate($c) if ($c->{generated_at} // 0) > time - $CACHE_TTL && ($c->{days} // 0) == $days;
    }
    my $since = time - $days * 86400;
    my @notes;
    my $db = $s->_state($since, \@notes);
    my $tasks = Comserv::Util::AI::TaskGrouper::group(%$db);
    $_->{start_pt} = _pt($_->{start}) for @$tasks;
    my $out = { generated_at => time, generated_pt => _pt(time), days => $days, since_pt => _pt($since),
                tasks => $tasks, notes => \@notes };
    _write_json($s->cache_file, $out);
    return $s->_decorate($out);
}

sub _decorate {
    my ($s, $out) = @_;
    my $r = $s->ratings;
    for my $t (@{ $out->{tasks} || [] }) {
        my $x = $r->{ $t->{id} };
        $t->{rating} = $x ? $x->{rating} : undef;
        $t->{rating_note} = $x ? $x->{note} : undef;
    }
    $out->{summary} = Comserv::Util::AI::TaskGrouper::summarize(tasks => $out->{tasks}, ratings => $r);
    $out->{rated} = scalar grep { $_->{rating} } @{ $out->{tasks} || [] };
    return $out;
}

sub _state {
    my ($s, $since, $notes) = @_;
    my $file = $ENV{HERMES_STATE_DB} || $s->hermes_home . '/state.db';
    my $out = { sessions => {}, msgs => {}, usage => {} };
    my $dbh = eval { DBI->connect("dbi:SQLite:dbname=$file", '', '', { RaiseError => 1, PrintError => 0, ReadOnly => 1 }) };
    unless ($dbh) { push @$notes, "state.db not readable: $@"; return $out }
    eval {
        my $r = $dbh->selectall_arrayref(q{SELECT id, title, model, parent_session_id, started_at, cwd, git_branch
            FROM sessions WHERE COALESCE(last_activity_at, started_at) >= CAST(? AS REAL)}, { Slice => {} }, $since);
        $out->{sessions}{ $_->{id} } = $_ for @$r;
        my $m = $dbh->selectall_arrayref(q{SELECT session_id, role, substr(COALESCE(content,''),1,3000) AS content, tool_calls, timestamp
            FROM messages WHERE timestamp >= ? AND role IN ('user','assistant') ORDER BY timestamp}, { Slice => {} }, $since);
        push @{ $out->{msgs}{ $_->{session_id} } }, $_ for @$m;
        my $u = $dbh->selectall_arrayref(q{SELECT session_id, model,
            CASE WHEN COALESCE(actual_cost_usd,0) > 0 THEN actual_cost_usd ELSE COALESCE(estimated_cost_usd,0) END AS usd,
            COALESCE(input_tokens,0) + COALESCE(output_tokens,0) + COALESCE(cache_read_tokens,0) AS tokens
            FROM session_model_usage WHERE last_seen >= ? AND COALESCE(task,'') = ''}, { Slice => {} }, $since);
        for my $x (@$u) {
            my $g = $out->{usage}{ $x->{session_id} } ||= { usd => 0, tokens => 0, models => [] };
            $g->{usd} += $x->{usd} || 0; $g->{tokens} += $x->{tokens} || 0;
            push @{ $g->{models} }, $x->{model} if $x->{model};
        }
        1;
    } or push @$notes, "state.db query failed: $@";
    $dbh->disconnect;
    return $out;
}

# Most recent task that edited one of @paths (for the reviewer's "author model").
sub author_for_paths {
    my ($s, @paths) = @_;
    my $b = $s->build;
    for my $t (@{ $b->{tasks} || [] }) {
        my %f = map { $_->{path} => 1 } @{ $t->{rewritten} || [] };
        for my $p (@paths) {
            return $t if grep { index($_, $p) >= 0 || index($p, $_) >= 0 } (keys %f, @{ $t->{edited_list} || [] });
        }
    }
    return undef;
}

1;
