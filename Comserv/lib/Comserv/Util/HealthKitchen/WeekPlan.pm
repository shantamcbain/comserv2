package Comserv::Util::HealthKitchen::WeekPlan;
use strict;
use warnings;
use utf8;

# Reusable, idempotent "week plan from inventory" feature.
#   ensure_food_bank_items($schema, $site)  - add Food Bank staples (if absent)
#   build_week($schema, %args)              - create recipes + a 7-day meal plan
# Recipes are whole-food, prevention-oriented templates. Each ingredient is
# matched to the site's inventory by pattern; unmatched ones are kept as ad_hoc
# lines and returned as a shopping list. Everything is matched by name, so
# re-running never duplicates items, recipes, plans or entries.

use Comserv::Util::CategoryManager;

our $SUPPLIER = 'Food Bank';

# name, category path, inventory match pattern, optional ENCY link [type, entity_id-finder]
our @FOOD_BANK = (
    { name => 'Potatoes',                path => 'Food > Produce > Potatoes',       match => qr/\bpotato(es)?\b(?!.*(churro|chip))/i },
    { name => 'Chicken Broth',           path => 'Food > Meat > Chicken',           match => qr/chicken (broth|stock)/i },
    { name => 'Spinach',                 path => 'Food > Produce > Leafy Greens',   match => qr/\bspinach\b/i },
    { name => 'Beets',                   path => 'Food > Produce > Other Produce',  match => qr/\bbeets?\b|beetroot/i },
    { name => 'Hamburger (ground beef)', path => 'Food > Meat > Beef',              match => qr/hamburger|ground beef/i,
      ency => [ animal => { common_name => 'Beef' } ] },
    { name => 'Frozen Corn',             path => 'Food > Grains > Corn',            match => qr/\bcorn\b(?!.*chip)/i },
    { name => 'Macaroni Pasta',          path => 'Food > Grains',                   match => qr/macaroni/i },
    { name => 'Lasagna Noodles',         path => 'Food > Grains',                   match => qr/lasagn/i },
    { name => 'Spaghetti (various)',     path => 'Food > Grains',                   match => qr/spaghetti|linguine|fettuccine/i },
    { name => 'Pasta Sauce (various)',   path => 'Food > Produce > Tomatoes',       match => qr/pasta sauce|marinara|tomato sauce/i },
    { name => 'Rolled Oats',             path => 'Food > Grains > Oats',            match => qr/rolled oats|oats reg rolled|oats.*rolled/i },
    { name => 'Onion',                   path => 'Food > Produce > Other Produce',  match => qr/\bonions?\b/i },
    { name => 'Canned Tuna',             path => 'Food > Seafood > Other Fish',     match => qr/\btuna\b/i },
);

# Ingredient key => inventory pattern (first match in name order wins).
our %ING = (
    oats => qr/oats reg rolled|rolled oats/i,           chia => qr/\bchia\b/i,
    pumpkin_seed => qr/seeds pumpkin|pumpkin seed/i,    hemp => qr/hemp hearts/i,
    raspberries => qr/raspberr/i,                       cinnamon => qr/cinnamon/i,
    yogurt => qr/yogurt org/i,                          walnut => qr/walnut/i,
    eggs => qr/^eggs/i,                                 spinach => qr/\bspinach\b/i,
    mushroom => qr/mushrooms crimini/i,                 shiitake => qr/shiitake/i,
    onion => qr/onions? yellow|^onion$|onions? red/i,   olive_oil => qr/olive oil/i,
    beets => qr/\bbeets?\b/i,                           spring_mix => qr/spring mix|lettuce/i,
    balsamic => qr/balsamic/i,                          potatoes => qr/^potatoes$/i,
    broth => qr/chicken broth/i,                        turmeric => qr/turmeric/i,
    pepper => qr/black pepper/i,                        tuna => qr/\btuna\b/i,
    tomato => qr/tomato on the vine|^tomato/i,          sauce => qr/pasta sauce/i,
    spaghetti => qr/spaghetti/i,                        lasagna => qr/lasagn/i,
    macaroni => qr/macaroni/i,                          beef => qr/hamburger|ground beef/i,
    corn => qr/frozen corn/i,                           cheese => qr/cheese emmental|250g cheese/i,
    sardines => qr/sardines/i,                          rye_bread => qr/sourdough rye/i,
    avocado => qr/avocado/i,                            sauerkraut => qr/sour kraut|sauerkraut/i,
    garlic => qr/\bgarlic\b/i,                          lemon => qr/\blemon\b/i,
    green_tea => qr/green tea/i,                        oregano_dried => qr/dried oregano|oregano leaf/i,
    parsley => qr/parsley/i,
);

our %LABEL = (
    oats => 'Rolled oats', chia => 'Chia seed', pumpkin_seed => 'Pumpkin seeds', hemp => 'Hemp hearts',
    raspberries => 'Frozen raspberries', cinnamon => 'Ceylon cinnamon', yogurt => 'Plain yogurt',
    walnut => 'Walnuts', eggs => 'Eggs', spinach => 'Spinach', mushroom => 'Crimini mushrooms',
    shiitake => 'Shiitake mushrooms', onion => 'Onion', olive_oil => 'Olive oil', beets => 'Beets',
    spring_mix => 'Spring mix greens', balsamic => 'Balsamic vinegar', potatoes => 'Potatoes',
    broth => 'Chicken broth', turmeric => 'Turmeric', pepper => 'Black pepper', tuna => 'Canned tuna',
    tomato => 'Fresh tomato', sauce => 'Pasta sauce', spaghetti => 'Spaghetti', lasagna => 'Lasagna noodles',
    macaroni => 'Macaroni', beef => 'Hamburger (lean ground beef)', corn => 'Frozen corn', cheese => 'Cheese',
    sardines => 'Sardines', rye_bread => 'Sourdough rye bread', avocado => 'Avocado', sauerkraut => 'Sauerkraut',
    garlic => 'Garlic', lemon => 'Lemon', green_tea => 'Green tea', oregano_dried => 'Dried oregano or basil',
    parsley => 'Fresh parsley',
);

# Recipe templates. ingredients: [key, quantity_text]; '?' suffix = optional.
our @RECIPES = (
    { code => 'HK-WK-OATS', name => 'Overnight oats with pumpkin seeds and berries', slot => 'breakfast', servings => 1,
      desc => 'High-fibre breakfast with zinc-rich pumpkin seeds and plant sterols. Make the night before.',
      steps => 'Mix oats, chia and cinnamon with yogurt and a little water; top with raspberries and seeds; chill overnight.',
      ing => [ [ oats => '1/2 cup' ], [ chia => '1 tbsp' ], [ pumpkin_seed => '2 tbsp' ], [ hemp => '1 tbsp', 1 ],
               [ raspberries => '1/2 cup' ], [ cinnamon => 'pinch' ], [ yogurt => '1/2 cup' ] ] },
    { code => 'HK-WK-SCRAM', name => 'Spinach and mushroom egg scramble', slot => 'breakfast', servings => 1,
      desc => 'Protein and leafy greens to start the day; no refined carbohydrate.',
      steps => 'Soften onion and mushrooms in olive oil, wilt spinach, add beaten eggs and stir gently. Pepper and turmeric to taste.',
      ing => [ [ eggs => '2' ], [ spinach => '1 handful' ], [ mushroom => '3-4' ], [ onion => '1/4' ], [ olive_oil => '1 tsp' ],
               [ pepper => 'pinch' ], [ turmeric => 'pinch' ] ] },
    { code => 'HK-WK-BEETSAL', name => 'Roasted beet and spinach salad with walnuts', slot => 'lunch', servings => 2,
      desc => 'Beets, greens and nuts: fibre, folate and healthy fats. Roast extra beets for the tray bake.',
      steps => 'Roast or boil beets until tender, cool and slice. Toss spinach and greens with olive oil and balsamic; top with beets, walnuts and pumpkin seeds.',
      ing => [ [ beets => '2 medium' ], [ spinach => '2 handfuls' ], [ spring_mix => '1 handful', 1 ], [ walnut => '2 tbsp' ],
               [ pumpkin_seed => '1 tbsp' ], [ olive_oil => '1 tbsp' ], [ balsamic => '2 tsp' ] ] },
    { code => 'HK-WK-SOUP', name => 'Potato, spinach and turmeric soup', slot => 'lunch', servings => 4,
      desc => 'Warming broth soup; makes 4 portions for later lunches. Eat at midday rather than late evening to limit night-time fluids.',
      steps => 'Soften onion (and garlic) in olive oil, add diced potatoes, turmeric and broth; simmer until soft, stir in spinach, season with pepper. Blend part if you like it thick.',
      ing => [ [ broth => '1 litre' ], [ potatoes => '3 medium' ], [ onion => '1' ], [ spinach => '2 handfuls' ],
               [ turmeric => '1 tsp' ], [ pepper => 'pinch' ], [ olive_oil => '1 tbsp' ], [ garlic => '2 cloves', 1 ] ] },
    { code => 'HK-WK-TUNASAL', name => 'Tuna and potato salad', slot => 'lunch', servings => 2,
      desc => 'Omega-3 fish with boiled potato and greens; yogurt instead of mayonnaise.',
      steps => 'Boil and cool potatoes, cube. Mix with tuna, finely chopped onion, yogurt, olive oil, pepper (and lemon). Serve on greens.',
      ing => [ [ tuna => '1 can' ], [ potatoes => '2' ], [ onion => '1/4' ], [ yogurt => '2 tbsp' ], [ olive_oil => '1 tsp' ],
               [ spring_mix => '1 handful' ], [ pepper => 'pinch' ], [ lemon => '1/2', 1 ], [ parsley => 'small bunch', 1 ] ] },
    { code => 'HK-WK-RYE', name => 'Sardines on sourdough rye with tomato and sauerkraut', slot => 'lunch', servings => 1,
      desc => 'Quick omega-3 lunch with whole-grain rye, cooked-tomato alternative and fermented vegetables.',
      steps => 'Toast rye bread, top with sardines, sliced tomato and avocado; sauerkraut on the side.',
      ing => [ [ sardines => '1 tin' ], [ rye_bread => '2 slices' ], [ tomato => '1' ], [ avocado => '1/2', 1 ], [ sauerkraut => '2 tbsp', 1 ] ] },
    { code => 'HK-WK-SPAG', name => 'Spaghetti with tomato, mushroom and spinach sauce', slot => 'dinner', servings => 3,
      desc => 'Cooked tomato sauce with olive oil makes lycopene more available. Moderate pasta portion, lots of vegetables.',
      steps => 'Soften onion and mushrooms in olive oil, add chopped tomato and pasta sauce, simmer 10 min, stir in spinach. Serve over a modest portion of spaghetti.',
      ing => [ [ spaghetti => '75 g per person' ], [ sauce => '1 jar' ], [ tomato => '2' ], [ mushroom => '1 cup' ],
               [ shiitake => 'few', 1 ], [ onion => '1' ], [ spinach => '2 handfuls' ], [ olive_oil => '1 tbsp' ],
               [ garlic => '2 cloves', 1 ], [ oregano_dried => '1 tsp', 1 ] ] },
    { code => 'HK-WK-LASAG', name => 'Lean beef, spinach and mushroom lasagna', slot => 'dinner', servings => 6,
      desc => 'Batch dinner: makes 6 portions for leftovers. Vegetables bulk up the sauce so less meat and cheese is needed.',
      steps => 'Brown hamburger with onion, drain fat, add pasta sauce and mushrooms. Layer noodles, sauce, spinach and a thin layer of cheese; bake covered 45 min at 375 F, uncover 10 min.',
      ing => [ [ lasagna => '9-12 noodles' ], [ beef => '450 g' ], [ sauce => '2 jars' ], [ spinach => '3 handfuls' ],
               [ mushroom => '2 cups' ], [ onion => '1' ], [ cheese => '1 cup grated' ], [ garlic => '2 cloves', 1 ],
               [ oregano_dried => '1 tsp', 1 ] ] },
    { code => 'HK-WK-SKILLET', name => 'Hamburger, corn and potato skillet', slot => 'dinner', servings => 3,
      desc => 'One-pan dinner; potatoes with skins for fibre, plenty of onion and corn.',
      steps => 'Brown hamburger with onion, drain. Add diced potatoes and a splash of broth, cover and cook until tender; add corn, turmeric and pepper; finish with spinach.',
      ing => [ [ beef => '300 g' ], [ potatoes => '3' ], [ corn => '1 cup' ], [ onion => '1' ], [ broth => '1/2 cup' ],
               [ turmeric => '1/2 tsp' ], [ pepper => 'pinch' ], [ spinach => '1 handful', 1 ] ] },
    { code => 'HK-WK-MACTUNA', name => 'Macaroni, tuna and tomato bake', slot => 'dinner', servings => 4,
      desc => 'Budget bake from food bank staples; tomato sauce and vegetables rather than a cream sauce.',
      steps => 'Cook macaroni until just firm. Mix with tuna, pasta sauce, corn and spinach; top with a little cheese and bake 20 min at 375 F.',
      ing => [ [ macaroni => '2 cups dry' ], [ tuna => '2 cans' ], [ sauce => '1 jar' ], [ corn => '1 cup' ], [ spinach => '2 handfuls' ],
               [ onion => '1/2' ], [ cheese => '1/2 cup grated' ] ] },
    { code => 'HK-WK-TRAY', name => 'Roasted beet, potato and onion tray with herb yogurt', slot => 'dinner', servings => 2,
      desc => 'Plant-based dinner; serve with a handful of pumpkin seeds and greens.',
      steps => 'Cube beets and potatoes, wedge onions, toss with olive oil, turmeric and pepper; roast 40 min at 400 F. Serve with yogurt, pumpkin seeds and greens.',
      ing => [ [ beets => '3' ], [ potatoes => '3' ], [ onion => '2' ], [ olive_oil => '1 tbsp' ], [ turmeric => '1/2 tsp' ],
               [ pepper => 'pinch' ], [ yogurt => '1/2 cup' ], [ pumpkin_seed => '2 tbsp' ], [ spring_mix => '1 handful', 1 ],
               [ parsley => 'small bunch', 1 ] ] },
);

# Day plan: slot => recipe code (or 'MORNING' for the existing Morning beverage recipe).
our @WEEK = (
    { breakfast => [ 'MORNING', 'HK-WK-OATS' ],  lunch => 'HK-WK-BEETSAL', dinner => 'HK-WK-LASAG' },
    { breakfast => [ 'MORNING', 'HK-WK-SCRAM' ], lunch => 'HK-WK-LASAG',   dinner => 'HK-WK-SKILLET', leftover => { lunch => 1 } },
    { breakfast => [ 'MORNING', 'HK-WK-OATS' ],  lunch => 'HK-WK-SOUP',    dinner => 'HK-WK-SPAG' },
    { breakfast => [ 'MORNING', 'HK-WK-SCRAM' ], lunch => 'HK-WK-SOUP',    dinner => 'HK-WK-MACTUNA', leftover => { lunch => 1 } },
    { breakfast => [ 'MORNING', 'HK-WK-OATS' ],  lunch => 'HK-WK-RYE',     dinner => 'HK-WK-LASAG',   leftover => { dinner => 1 } },
    { breakfast => [ 'MORNING', 'HK-WK-SCRAM' ], lunch => 'HK-WK-TUNASAL', dinner => 'HK-WK-TRAY' },
    { breakfast => [ 'MORNING', 'HK-WK-OATS' ],  lunch => 'HK-WK-SOUP',    dinner => 'HK-WK-MACTUNA', leftover => { lunch => 1, dinner => 1 } },
);

# Pure: first inventory item whose name matches the ingredient key.
sub match_item {
    my ( $key, $items ) = @_;
    my $rx = $ING{$key} or return undef;
    for my $it ( sort { lc $a->{name} cmp lc $b->{name} } @$items ) {
        return $it if $it->{name} =~ $rx;
    }
    return undef;
}

# Pure: { key => item|undef } for all template ingredients plus the shopping gaps.
sub plan_ingredients {
    my ($items) = @_;
    my ( %m, %gap );
    for my $r (@RECIPES) {
        for my $i ( @{ $r->{ing} } ) {
            my ( $k, undef, $opt ) = @$i;
            $m{$k} //= match_item( $k, $items );
            push @{ $gap{$k}{recipes} }, $r->{name} unless $m{$k};
            $gap{$k}{optional} = 1 if !$m{$k} && $opt && !exists $gap{$k}{required};
            $gap{$k}{required} = 1 if !$m{$k} && !$opt;
        }
    }
    my @gaps = map { { key => $_, label => $LABEL{$_} // $_, optional => ( $gap{$_}{required} ? 0 : 1 ),
                       recipes => $gap{$_}{recipes} } } sort keys %gap;
    return ( \%m, \@gaps );
}

sub _items {
    my ( $schema, $site ) = @_;
    return [ map { +{ id => $_->id, name => $_->name } }
        $schema->resultset('Accounting::InventoryItem')->search( { sitename => $site, status => 'active' } )->all ];
}

my %ITEM_DEFAULTS = ( category => 'food', unit_of_measure => 'each', item_origin => 'purchased', is_consumable => 1,
    is_assemblable => 0, is_reusable => 0, hide_stock_count => 0, show_in_shop => 0, accepts_points => 0,
    requires_printing => 0, list_in_marketplace => 0, reorder_point => 0, reorder_quantity => 0,
    discount_percent => 0, status => 'active', created_by => 'system' );

sub _sku { my $n = uc shift; $n =~ s/\(.*?\)//g; $n =~ s/[^A-Z0-9]+/-/g; $n =~ s/^-|-$//g; 'FB-' . substr( $n, 0, 40 ) }

# Add Food Bank staples. Returns { created => [names], existing => [names] }.
sub ensure_food_bank_items {
    my ( $schema, $site ) = @_;
    my %out = ( created => [], existing => [] );
    my $cm = Comserv::Util::CategoryManager->new;
    $schema->txn_do( sub {
        my $sup = $schema->resultset('Accounting::InventorySupplier')->search( { sitename => $site, name => $SUPPLIER } )->first
            || $schema->resultset('Accounting::InventorySupplier')->create( { sitename => $site, name => $SUPPLIER,
                   status => 'active', created_by => 'system', notes => 'Donated food. unit_cost 0.' } );
        my %path = map { $_->{path} => $_->{id} } @{ $cm->options_for_site( $schema, $site, {} ) };
        my $items = _items( $schema, $site );
        my $IR = $schema->resultset('Accounting::InventoryItem');
        for my $f (@FOOD_BANK) {
            my ($have) = grep { $_->{name} =~ $f->{match} } @$items;
            if ($have) { push @{ $out{existing} }, "$f->{name} (= #$have->{id} $have->{name})"; next }
            my $it = $IR->create( { %ITEM_DEFAULTS, sitename => $site, name => $f->{name}, sku => _sku( $f->{name} ),
                category => $f->{path}, unit_cost => 0, description => 'Food Bank',
                notes => 'Food Bank item (donated, unit_cost 0).' } );
            $cm->set_item_categories( $schema, $it->id, [ $path{ $f->{path} } ] ) if $path{ $f->{path} };
            $schema->resultset('Accounting::InventoryItemSupplier')->create( { item_id => $it->id, supplier_id => $sup->id,
                unit_cost => 0, is_preferred => 1 } );
            if ( eval { $schema->resultset('Accounting::InventoryItemAttributes')->count; 1 } ) {
                $schema->resultset('Accounting::InventoryItemAttributes')->create( { item_id => $it->id, sitename => $site,
                    food_category_id => $path{ $f->{path} }, production => 'conventional', animal_raising => undef,
                    catch_method => undef, gmo => 'unknown' } );
            }
            if ( my $e = $f->{ency} ) {
                my ( $type, $q ) = @$e;
                my $src = { animal => 'Ency::Animal', herb => 'Ency::Herb' }->{$type};
                my $ent = $src && $schema->resultset($src)->search($q)->first;
                $schema->resultset('HealthKitchen::InventoryEncyLink')->create( { sitename => $site, item_kind => 'inventory',
                    item_id => $it->id, entity_type => $type, entity_id => $ent->id, notes => 'Food Bank seed' } ) if $ent;
            }
            push @{ $out{created} }, $f->{name};
            push @$items, { id => $it->id, name => $it->name };
        }
    } );
    return \%out;
}

# Build recipes + 7-day plan. args: site, user_id, username, start_date (YYYY-MM-DD), plan_name.
sub build_week {
    my ( $schema, %a ) = @_;
    my $site = $a{site} or die "site required\n";
    my ( $m, $gaps ) = plan_ingredients( _items( $schema, $site ) );
    my %rid;
    my %n = ( recipes_created => 0, lines_created => 0, entries_created => 0, plan_created => 0 );
    $schema->txn_do( sub {
        my $R = $schema->resultset('Recipe');
        my $mb = $R->search( { sitename => $site, name => 'Morning beverage' } )->first;
        $rid{MORNING} = $mb->id if $mb;
        for my $t (@RECIPES) {
            my $r = $R->search( { sitename => $site, recipe_code => $t->{code} } )->first;
            unless ($r) {
                $r = $R->create( { sitename => $site, recipe_code => $t->{code}, name => $t->{name}, recipe_kind => 'food_recipe',
                    status => 'active', description => $t->{desc}, instructions => $t->{steps}, servings => $t->{servings},
                    source => 'healthkitchen_week_plan', username_of_poster => $a{username} } );
                $n{recipes_created}++;
                my $o = 0;
                for my $i ( @{ $t->{ing} } ) {
                    my ( $k, $q, $opt ) = @$i;
                    my $it = $m->{$k};
                    $schema->resultset('RecipeLine')->create( { recipe_id => $r->id, sort_order => ++$o,
                        ingredient_source => ( $it ? 'inventory' : 'ad_hoc' ), inventory_item_id => ( $it ? $it->{id} : undef ),
                        name_raw => $LABEL{$k} // $k, quantity_text => $q, is_optional => ( $opt ? 1 : 0 ),
                        notes => ( $it ? undef : 'not in stock' ) } );
                    $n{lines_created}++;
                }
            }
            $rid{ $t->{code} } = $r->id;
        }
        if ( $a{user_id} && $a{start_date} && $a{start_date} =~ /^(\d{4})-(\d{2})-(\d{2})$/ ) {
            require Time::Local;
            my $t0 = Time::Local::timegm( 0, 0, 12, $3, $2 - 1, $1 );
            my $d  = sub { my @t = gmtime( $t0 + 86400 * shift ); sprintf '%04d-%02d-%02d', $t[5] + 1900, $t[4] + 1, $t[3] };
            my $name = $a{plan_name} || "Week from inventory $a{start_date}";
            my $P = $schema->resultset('HealthKitchen::MealPlan');
            my $plan = $P->search( { user_id => $a{user_id}, sitename => $site, name => $name } )->first;
            unless ($plan) {
                $plan = $P->create( { user_id => $a{user_id}, sitename => $site, name => $name, start_date => $a{start_date},
                    end_date => $d->(6), status => 'draft', notes => 'Generated by HealthKitchen week plan from inventory.' } );
                $n{plan_created} = 1;
            }
            $n{plan_id} = $plan->id;
            for my $i ( 0 .. $#WEEK ) {
                my $day = $WEEK[$i];
                for my $slot (qw(breakfast lunch dinner)) {
                    for my $code ( ref $day->{$slot} ? @{ $day->{$slot} } : $day->{$slot} ) {
                        my $id = $rid{$code} or next;
                        my $date = $d->($i);
                        next if $plan->entries->search( { plan_date => $date, meal_slot => $slot, recipe_id => $id } )->count;
                        $plan->create_related( entries => { plan_date => $date, meal_slot => $slot, recipe_id => $id, servings => 1,
                            notes => ( $day->{leftover}{$slot} ? 'leftovers' : undef ) } );
                        $n{entries_created}++;
                    }
                }
            }
        }
    } );
    return { %n, recipe_ids => \%rid, shopping => $gaps };
}

1;
