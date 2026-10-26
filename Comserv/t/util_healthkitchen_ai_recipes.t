use strict;
use warnings;
use Test::More;
use Comserv::Util::HealthKitchen;

my $hk = Comserv::Util::HealthKitchen->new;
my $foods = $hk->ai_stock_foods( [
    { inventory_item_id => 10, name => 'Rolled oats', qty => 900, unit => 'g' },
    { inventory_item_id => 11, name => 'Apples',      qty => 4,   unit => 'each' },
    { inventory_item_id => 12, name => 'Lentils',     qty => 0,   unit => 'g' },
    { name => 'personal salt', qty => 1 },
] );
is( scalar @$foods, 2, 'only in-stock, inventory-mapped foods offered to AI' );
like( $hk->ai_recipe_prompt($foods), qr/id=10; name=Rolled oats/, 'prompt lists stock ids' );

my $mock = '```json
[{"name":"Apple oat bowl","servings":2,"instructions":["Cook oats","Add apple"],
  "ingredients":[{"inventory_item_id":10,"quantity":100,"unit":"g"},{"name":"Apples","quantity":1},{"name":"water"}]},
 {"name":"Saffron rice","ingredients":[{"inventory_item_id":99,"quantity":1}]}]
```';
my $r = $hk->parse_ai_recipes( $mock, $foods );
is( scalar @$r, 1, 'recipe with unstocked ingredient rejected' );
is( $r->[0]{name}, 'Apple oat bowl', 'valid recipe kept' );
is( scalar @{ $r->[0]{lines} }, 2, 'water skipped, two inventory lines' );
is( $r->[0]{lines}[1]{inventory_item_id}, 11, 'name mapped to inventory id' );
like( $r->[0]{instructions}, qr/Cook oats\nAdd apple/, 'array instructions joined' );
is_deeply( $hk->parse_ai_recipes( 'sorry, no JSON', $foods ), [], 'garbage response -> none' );

# generate_ai_recipes with the AI call mocked and a fake Catalyst context
{
    package FakeRS;  sub new { my ( $cl, $log, $src ) = @_; bless { log => $log, src => $src }, $cl }
    my $id = 0;
    sub create { my ( $s, $h ) = @_; push @{ $s->{log} }, [ $s->{src}, $h ]; return FakeRow->new( ++$id ) }
    sub search { $_[0] } sub count { 0 }
    package FakeRow; sub new { bless { id => $_[1] }, $_[0] } sub id { $_[0]{id} }
    package FakeSchema; sub new { bless { log => [] }, shift } sub resultset { FakeRS->new( $_[0]{log}, $_[1] ) }
    sub source { 1 } sub txn_do { $_[1]->() }
    package FakeC; sub new { bless { s => FakeSchema->new }, shift } sub model { $_[0]{s} }
    sub session { { username => 'tester', user_id => 1, SiteName => 'TestSite' } } sub stash { { SiteName => 'TestSite' } }
}
no warnings 'redefine';
local *Comserv::Util::HealthKitchen::recipe_ready = sub { 1 };
local *Comserv::Util::HealthKitchen::list_pantry  = sub { [
    { inventory_item_id => 10, name => 'Rolled oats', qty => 900, unit => 'g' },
    { inventory_item_id => 11, name => 'Apples', qty => 4, unit => 'each' } ] };
local *Comserv::Util::HealthKitchen::sitename = sub { 'TestSite' };
my $c = FakeC->new;
my $seen_prompt;
my $res = $hk->generate_ai_recipes( $c, { ai_call => sub { $seen_prompt = shift; { success => 1, response => $mock, model => 'mock' } } } );
ok( $res->{ok}, 'generate ok with mocked AI' ) or diag explain $res;
like( $seen_prompt, qr/Rolled oats/, 'AI got stock list' );
my @recs = grep { $_->[0] eq 'Ency::Recipe' } @{ $c->{s}{log} };
is( scalar @recs, 1, 'one recipe saved' );
is( $recs[0][1]{source}, 'ai_generated', 'marked AI-generated' );
is( $recs[0][1]{status}, 'draft', 'saved as draft for review' );
is( $recs[0][1]{sitename}, 'TestSite', 'scoped to sitename' );
like( $recs[0][1]{notes}, qr/not medical advice/, 'review/disclaimer note' );
my @lines = grep { $_->[0] eq 'Ency::RecipeLine' } @{ $c->{s}{log} };
ok( !( grep { $_->[1]{ingredient_source} ne 'inventory' || !$_->[1]{inventory_item_id} } @lines ), 'all lines map to inventory' );
my $fail = $hk->generate_ai_recipes( $c, { ai_call => sub { { success => 0, error => 'quota' } } } );
like( $fail->{error}, qr/quota/, 'AI failure reported, nothing saved' );
done_testing;
