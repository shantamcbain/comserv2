use strict; use warnings; use lib 'lib';
use Test::More;
use Comserv::Util::HealthKitchen::SlotRecipe;
my $SR = 'Comserv::Util::HealthKitchen::SlotRecipe';

# --- tag parsing
is $SR->parse_recipe_tag("hk_day_slot:first_drink\nhk_recipe:12"), 12, 'tag parsed';
is $SR->parse_recipe_tag('hk_recipe:7'), 7, 'tag at start';
ok !defined $SR->parse_recipe_tag('no tag here'), 'untagged -> undef';
ok !defined $SR->parse_recipe_tag('xhk_recipe:5'), 'embedded word not a tag';
ok !defined $SR->parse_recipe_tag(undef), 'undef comments';
is $SR->parse_slot('hk_day_slot:first_drinkWORK_ORDER_NEEDED: x'), 'first_drink', 'slot stops at junk';
is $SR->line_text({ quantity => '1.00', unit => 'tsp', name_raw => 'Turmeric' }), '1 tsp Turmeric', 'line text';
is $SR->line_text({ quantity_text => 'pinch', name_raw => 'Pepper', is_optional => 1 }), 'pinch Pepper (optional)', 'qty text';

# --- fakes (search honours me.-prefixed equality keys)
our $WRITES = 0;
{ package FRow; sub new { my ($c,%a)=@_; bless {%a}, $c }
  our $AUTOLOAD; sub AUTOLOAD { my $s=shift; (my $n=$AUTOLOAD)=~s/.*:://; return if $n eq 'DESTROY'; $s->{$n} }
  sub get_columns { %{ $_[0] } } sub update { $main::WRITES++ } sub delete { $main::WRITES++ }
  sub lines { my $s=shift; FRS->new(@{ $s->{_lines} || [] }) } }
{ package FRS; sub new { my $c=shift; bless [@_], $c } sub all { @{$_[0]} } sub single { $_[0][0] } sub next { shift @{$_[0]} }
  sub create { $main::WRITES++ } sub update { $main::WRITES++ }
  sub search { my ($s,$q)=@_; FRS->new(grep { my $r=$_; !grep { my $k=$_; (my $f=$k)=~s/^me\.//; !ref $q->{$k} && ($r->{$f}//'') ne $q->{$k} } keys %$q } @$s) } }
my @recipes = (
  FRow->new(id=>1, name=>'Morning beverage', sitename=>'Shanta', username_of_poster=>'Shanta', _lines=>[FRow->new(sort_order=>1, name_raw=>'Coffee', quantity=>1, unit=>'cup')]),
  FRow->new(id=>2, name=>'Overnight oats', sitename=>'Shanta', username_of_poster=>'Shanta', _lines=>[]),
  FRow->new(id=>3, name=>'Other owner', sitename=>'Shanta', username_of_poster=>'Mallory', _lines=>[]),
  FRow->new(id=>4, name=>'Other site', sitename=>'CSC', username_of_poster=>'Shanta', _lines=>[]),
  FRow->new(id=>5, name=>'Morning beverage', sitename=>'CSC', username_of_poster=>'Mallory', _lines=>[]),
);
my @entries = ( FRow->new(recipe_id=>1), FRow->new(recipe_id=>2) );
{ package FSchema; sub new { bless {}, shift }
  sub resultset { my ($s,$n)=@_; return FRS->new(@recipes) if $n eq 'Recipe'; return bless {}, 'FEntRS' } }
{ package FEntRS; sub search { my ($s,$q)=@_; FRS->new($q->{'me.meal_slot'} eq 'breakfast' ? @entries : ()) } }
my $schema = FSchema->new;
my $me = { username => 'Shanta', sitename => 'Shanta' };

my $drink = FRow->new(record_id=>10, user_id=>178, subject=>'First drink', comments=>'hk_day_slot:first_drink');
my $bfast = FRow->new(record_id=>11, user_id=>178, subject=>'Breakfast', comments=>'hk_day_slot:breakfast');
my $plain = FRow->new(record_id=>12, user_id=>178, subject=>'Pay bills', comments=>'call bank');
my $tagd  = FRow->new(record_id=>13, user_id=>178, subject=>'X', comments=>'hk_day_slot:happy_hour hk_recipe:2');

my $cards = $SR->cards_for_todos($schema, [$drink, $bfast, $plain], '2026-11-09', 178, $me);
is $cards->{10}{name}, 'Morning beverage', 'fixed slot resolves (own recipe, not CSC/Mallory id 5)';
is $cards->{10}{id}, 1, 'fixed slot picks owner+site recipe';
is_deeply $cards->{10}{ingredients}, ['1 cup Coffee'], 'ingredients listed';
is $cards->{10}{url}, '/healthkitchen/recipes#recipe-1', 'view recipe link';
is $cards->{11}{name}, 'Overnight oats', 'breakfast from plan, skipping first-drink recipe';
is $SR->cards_for_todos($schema, [$tagd], '2026-11-09', 178, $me)->{13}{id}, 2, 'explicit own tag honoured';
ok !exists $cards->{12}, 'untagged todo gets no card';
is $drink->{subject}, 'First drink', 'subject not persisted (display only)';

# --- owner/site scoping: forged / cross-owner / cross-site tags => no card
for ([3,'cross-owner'], [4,'cross-site'], [999,'nonexistent']) {
  my $t = FRow->new(record_id=>20, user_id=>178, comments=>"hk_recipe:$_->[0]");
  ok !exists $SR->cards_for_todos($schema, [$t], '2026-11-09', 178, $me)->{20}, "$_->[1] tag => no card";
}
ok !$SR->recipe_card($schema, 3, $me), 'recipe_card refuses other owner';
ok !$SR->recipe_card($schema, 4, $me), 'recipe_card refuses other site';
ok !$SR->recipe_card($schema, 1, { username => 'Shanta' }), 'no site => fail closed';
ok !$SR->recipe_card($schema, 1, undef), 'no owner => fail closed';
ok !$SR->recipe_card($schema, '1 OR 1', $me), 'non-numeric id refused';
my $other = FRow->new(record_id=>21, user_id=>999, comments=>'hk_day_slot:first_drink');
ok !exists $SR->cards_for_todos($schema, [$other], '2026-11-09', 178, $me)->{21}, "someone else's todo gets no card";
is_deeply $SR->cards_for_todos($schema, [$drink], '2026-11-09', undef, $me), {}, 'no user => no cards';

# --- GET day view is read-only
is $WRITES, 0, 'card derivation performed no DB writes';
ok !$SR->can($_), "no $_ in SlotRecipe" for qw(sync_fixed_slots _backup_row add_recipe_tag);
my $src = do { local $/; open my $h,'<','lib/Comserv/Util/HealthKitchen/SlotRecipe.pm' or die; <$h> };
unlike $src, qr/->(update|create|delete|update_or_create|txn_do)\b/, 'SlotRecipe has no write calls';
my $todo = do { local $/; open my $h,'<','lib/Comserv/Controller/Todo.pm' or die; <$h> };
my ($blk) = $todo =~ /(# Health Kitchen day slots.*?hk slot recipe lookup failed)/s;
ok $blk, 'day view hk block found';
unlike $blk, qr/sync|->update|backup/, 'day view hk block does not persist';

# --- template / JS
my $tt = do { local $/; open my $h,'<','root/todo/day.tt' or die; <$h> };
like $tt, qr/data-hk-recipe-id="\[% hkr\.id %\]"/, 'day.tt tags card with recipe id';
like $tt, qr/href="\[% hkr\.url %\]" target="_top" class="hk-recipe-view">view recipe/, 'view recipe link rendered';
like $tt, qr/HkRecipeConfirm\.open\(hkEv/, 'lockDay opens in-place confirm instead of navigating';
like $tt, qr/closest\('\.hk-recipe-info, \.hk-recipe-confirm'\)\) return/, 'panel clicks are not Done clicks';
my $js = do { local $/; open my $h,'<','root/static/js/healthkitchen/recipe-confirm.js' or die; <$h> };
like $js, qr{/healthkitchen/recipe_make/}, 'confirm posts to recipe_make';
like $js, qr/credentials: 'same-origin'/, 'confirm posts same-origin';
unlike $js, qr/location\.(href|assign)/, 'confirm never navigates';
done_testing;
