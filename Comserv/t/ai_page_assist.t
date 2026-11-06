use strict; use warnings;
use Test::More;
use lib 'lib';
use Comserv::Model::AI2::PageAssist;
use Comserv::Model::AI2::ChatIntent qw(looks_like_page_create);

# --- fakes ---
{ package FakeLog; sub new { bless {}, shift } sub log_with_details { 1 } }
{ package FakeRouter;
  sub new { my ($c, %a) = @_; bless { %a, calls => [] }, $c }
  sub supergrok_guard { { locked => $_[0]{locked} } }
  sub dispatch_chat { my ($s, $c, $m, $msgs, %o) = @_; push @{$s->{calls}}, { model => $m, %o };
      my $r = $s->{reply}->($m); return $r } }
{ package FakeC; sub new { bless {}, shift } sub model { $_[0]{router} } }

my $pa = Comserv::Model::AI2::PageAssist->new(logging => FakeLog->new);
my $c  = FakeC->new;

# Phase 1: allowed models never include banned ones
my @ok = @{ $pa->allowed_models };
is_deeply \@ok, ['supergrok|grok-4.7','openrouter|particle-ai/particle-1','openrouter|openai/gpt-5.6-luna'], 'writing chain';
ok !(grep { /mercury|seed|v4-pro|glm|relace/i } @ok), 'no banned models';

my $r = FakeRouter->new(locked => 1, reply => sub { { success => 1, response => '<h2>Hi</h2><script>x</script><p onclick="y">t</p>', provider => 'openrouter', model => 'particle-ai/particle-1' } });
my $out = $pa->assist($c, action => 'rewrite', text => '<p>old</p>', title => 'T', router => $r);
ok $out->{success}, 'assist ok';
is $r->{calls}[0]{model}, 'openrouter|particle-ai/particle-1', 'Super Grok skipped when locked';
is $r->{calls}[0]{failover}, 0, 'router failover off';
is $r->{calls}[0]{log_usage}, 'page_assist', 'ledgered as page_assist';
unlike $out->{html}, qr/script|onclick/i, 'html cleaned';

$r = FakeRouter->new(locked => 0, reply => sub { $_[0] =~ /supergrok/ ? { success => 0, error => 'quota' } : { success => 1, response => '<p>x</p>', provider => 'openrouter', model => 'openai/gpt-5.6-luna' } });
$out = $pa->assist($c, action => 'draft', title => 'T', router => $r);
is scalar @{$r->{calls}}, 2, 'falls to particle-1 after Super Grok fails';

$r = FakeRouter->new(reply => sub { { success => 1, response => '<p>x</p>', provider => 'openrouter', model => 'inception/mercury-2' } });
$out = $pa->assist($c, action => 'draft', title => 'T', router => $r);
ok !$out->{success}, 'reply from a banned model is discarded';

ok !$pa->assist($c, action => 'rewrite', text => '', router => $r)->{success}, 'rewrite needs text';
ok !$pa->assist($c, action => 'hack', router => $r)->{success}, 'unknown action refused';

# Phase 2: writer JSON parse
my $d = $pa->parse_write_reply("```json\n{\"title\":\"Yarrow\",\"page_code\":\"Yarrow Herb\",\"body\":\"<p>x</p>\"}\n```");
is $d->{title}, 'Yarrow', 'parse writer reply';
ok !$pa->parse_write_reply('no json here'), 'bad reply rejected';
$r = FakeRouter->new(locked => 1, reply => sub { { success => 1, response => '{"title":"Yarrow Notes","page_code":"Yarrow Notes!","description":"d","keywords":"k","body":"<h2>A</h2>"}', provider => 'openrouter', model => 'particle-ai/particle-1' } });
$out = $pa->write_page($c, topic => 'yarrow', router => $r);
is $out->{page}{page_code}, 'yarrow_notes', 'page code slugged';

# Phase 4: chat intent
is looks_like_page_create('Please create a page about printer maintenance.'), 'printer maintenance', 'page intent';
is looks_like_page_create('create a todo about the page'), '', 'todo not stolen';
is looks_like_page_create('how do I create a page about x'), '', 'how-to not an intent';

done_testing;
