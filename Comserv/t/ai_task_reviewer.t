use strict; use warnings; use Test::More;
use FindBin; use lib "$FindBin::Bin/../lib";
use File::Temp qw(tempdir);
use JSON::PP;
use Comserv::Util::AI::TaskGrouper;
use Comserv::Util::AI::CodeReviewer;
use Comserv::Model::AI2::TaskTracker;

# --- TaskGrouper ---
my $T0 = 1_760_000_000;
my $edit = encode_json([ { function => { name => 'patch', arguments => encode_json({ path => 'lib/A.pm' }) } } ]);
my %sessions = (s1 => { id => 's1', model => 'grok-4.7', title => 'Fix A', started_at => $T0 },
                s2 => { id => 's2', model => 'z-ai/glm-5.3-flash', parent_session_id => 's1', started_at => $T0 + 600 });
my %msgs = (
  s1 => [ { role => 'user', content => 'fix A please', timestamp => $T0 },
          map({ { role => 'assistant', content => '', tool_calls => $edit, timestamp => $T0 + 60 * $_ } } 1 .. 3),
          { role => 'user', content => "that's wrong, still broken", timestamp => $T0 + 300 } ],
  s2 => [ { role => 'assistant', content => 'ok', timestamp => $T0 + 610 },
          { role => 'user', content => 'new thing', timestamp => $T0 + 610 + 3600 },
          { role => 'assistant', content => 'done', timestamp => $T0 + 610 + 3660 } ],
);
my %usage = (s1 => { usd => 0, tokens => 3000, models => ['grok-4.7'] }, s2 => { usd => 1.0, tokens => 1000, models => ['z-ai/glm-5.3-flash'] });
my $tasks = Comserv::Util::AI::TaskGrouper::group(sessions => \%sessions, msgs => \%msgs, usage => \%usage);
is(scalar @$tasks, 2, 'child session continues parent; 60 min gap starts a new task');
my ($first) = grep { $_->{start} == $T0 } @$tasks;
is($first->{edits}, 3, '3 edits counted');
is($first->{rewritten}[0]{path}, 'lib/A.pm', 'same file 3x = rewritten');
ok($first->{corrections} >= 1, 'correction phrase counted');
is($first->{guess}, 'partial?', 'guess partial');
ok(abs($first->{active_min} - 10.2) < 0.01, 'active minutes skip long idle gaps') or diag $first->{active_min};
my $sum = Comserv::Util::AI::TaskGrouper::summarize(tasks => $tasks, ratings => { $tasks->[0]{id} => { rating => 'done' } });
my ($g) = grep { $_->{done} } @$sum;
ok($g && defined $g->{usd_per_done}, 'usd per Done computed');

# --- ratings ---
my $dir = tempdir(CLEANUP => 1); mkdir "$dir/data";
my $tt = Comserv::Model::AI2::TaskTracker->new(root => $dir);
ok(!$tt->rate('s1:1760000000', 'done', note => 'ok', by => 'test'), 'rating saved');
is($tt->ratings->{'s1:1760000000'}{rating}, 'done', 'rating read back');
ok($tt->rate('bad id', 'done'), 'bad id refused');
ok($tt->rate('s1:1', 'great'), 'bad rating refused');

# --- CodeReviewer ---
is(Comserv::Util::AI::CodeReviewer::vendor('openrouter/anthropic/claude-sonnet-5.5'), 'anthropic', 'vendor anthropic');
is(Comserv::Util::AI::CodeReviewer::vendor('grok-build-0.1'), 'xai', 'vendor xai');
is(Comserv::Util::AI::CodeReviewer::vendor('openai/gpt-6-sol'), 'openai', 'vendor openai');
open my $fh, '>', "$dir/data/ai_reviewer.json"; print $fh encode_json({ enabled => 1, cap_usd_per_day => 0.5,
  primary => 'anthropic/claude-sonnet-5.5', alternate => 'openai/gpt-6-sol',
  prices => { 'anthropic/claude-sonnet-5.5' => { in => 2, out => 10 }, 'openai/gpt-6-sol' => { in => 2, out => 10 } }, max_tokens => 1500 }); close $fh;
my $rv = Comserv::Util::AI::CodeReviewer->new(root => $dir);
is(($rv->pick_model(author_models => ['grok-4.7']))[0], 'anthropic/claude-sonnet-5.5', 'primary for grok author');
is(($rv->pick_model(author_models => ['claude-opus-5.5']))[0], 'openai/gpt-6-sol', 'alternate when author is anthropic');
ok(!($rv->pick_model(author_models => ['anthropic/claude-x', 'openai/gpt-6']))[0], 'skip when both vendors are authors');

{ package T::Prov; my @calls; sub new { bless {}, shift } sub calls { \@calls }
  sub chat { my ($s, $c, %a) = @_; push @calls, \%a;
    return { success => 1, model => $a{model}, response => '{"correctness":2,"security":1,"quality":3,"verdict":"warn","summary":"sql injection","findings":[{"file":"x","line":3,"severity":"high","reason":"raw SQL"}]}',
             usage => { prompt_tokens => 1000, completion_tokens => 200, cost => 0.004 } } } }
{ package T::Usage; my @rows; sub new { bless {}, shift } sub rows { \@rows } sub log { my ($s, $c, %a) = @_; push @rows, \%a } }
my $prov = T::Prov->new; my $use = T::Usage->new;
my $r = $rv->review(undef, diff => "+my \$x = 1;\n", author_models => ['grok-4.7'], provider => $prov, usage_model => $use);
ok($r->{ok}, 'review ok');
is($r->{review}{security}, 1, 'scores parsed');
is($r->{usd}, 0.004, 'billed cost used');
is(T::Usage->rows->[0]{request_type}, 'code_review', 'own Ledger row written');
is($prov->calls->[0]{purpose}, 'code_review', 'provider call tagged code_review');
is(($rv->spent_today)[0], 0.004, 'spend counted');
my $skip = $rv->review(undef, diff => '', provider => $prov, usage_model => $use);
ok($skip->{skipped}, 'empty diff skipped');
open $fh, '>', "$dir/data/ai_reviewer_spend.json"; print $fh encode_json({ $rv->today_pt => { usd => 0.499, calls => 9 } }); close $fh;
my $n = scalar @{ $prov->calls };
my $cap = $rv->review(undef, diff => "+x\n" x 100, author_models => [], provider => $prov, usage_model => $use);
ok($cap->{skipped} && $cap->{reason} =~ /cap/, 'hard cap refuses the call');
is(scalar @{ $prov->calls }, $n, 'no provider call over cap');

done_testing();
