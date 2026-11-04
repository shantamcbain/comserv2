use strict; use warnings; use Test::More;
use FindBin; use lib "$FindBin::Bin/../lib";
plan skip_all => 'DBD::SQLite/SQL::Translator missing' unless eval { require DBD::SQLite; require SQL::Translator; 1 };
require Comserv::Model::Schema::Ency; require Comserv::Model::AI::Usage; require JSON::PP;
my $s = Comserv::Model::Schema::Ency->connect('dbi:SQLite:dbname=:memory:', '', '', { RaiseError => 1, PrintError => 0 });
$s->deploy({ sources => ['AiUsageLog'], add_drop_table => 0 });
{ package FakeModel; sub new { bless { s => $_[1] }, $_[0] } sub schema { $_[0]{s} } sub get_ai_daily_quota_for_site { 0 } }
{ package FakeReq; sub new { bless {}, shift } sub address { '127.0.0.1' } }
{ package FakeC; sub new { my ($cl, %a) = @_; bless { %a, stash => $a{stash} || {} }, $cl }
  sub model { my ($s, $n) = @_; return $n eq 'DBEncy' ? FakeModel->new($s->{schema}) : undef } sub session { $_[0]{session} }
  sub stash { $_[0]{stash} } sub request { FakeReq->new } sub config { {} } sub path_to { '.' } }
my $c = FakeC->new(schema => $s, session => { user_id => 42, username => 'alice', SiteName => 'CSC' },
                   stash => { ai_key_tags => { key_owner => 'user', key_row_id => 9, billing_status => 'user_key', bill_to_user_id => 42 } });
Comserv::Model::AI::Usage->new->log($c, provider => 'openrouter', model => 'openai/gpt-x', prompt_tokens => 5, completion_tokens => 5, response_text => 'ok');
my $row = $s->resultset('AiUsageLog')->search({}, { order_by => { -desc => 'id' } })->first;
ok $row, 'row written';
is $row->billing_status, 'user_key', "user's own key -> billing_status user_key (excluded from shared caps)";
my $m = JSON::PP::decode_json($row->metadata);
is $m->{key_owner}, 'user', 'key_owner tagged';
is $m->{bill_to_user_id}, 42, 'bill_to_user_id tagged';
is $m->{username}, 'alice', 'still tagged by user';
is $m->{sitename}, 'CSC', 'still tagged by sitename';
ok exists $m->{branch}, 'still tagged by branch';
$c->{stash} = {};
Comserv::Model::AI::Usage->new->log($c, provider => 'openrouter', model => 'openai/gpt-x', prompt_tokens => 5, completion_tokens => 5, response_text => 'ok');
$row = $s->resultset('AiUsageLog')->search({}, { order_by => { -desc => 'id' } })->first;
isnt $row->billing_status // '', 'user_key', 'owner/shared key row is not user_key';
done_testing;
