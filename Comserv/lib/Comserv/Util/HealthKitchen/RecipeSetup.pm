package Comserv::Util::HealthKitchen::RecipeSetup;

# One-button, idempotent recipe setup (app code; POST /healthkitchen/setup_apply):
#  * Morning beverage (owner+site): weighed per-serving grams, pepper = pinch
#    (never deducted), add collagen line.
#  * Home "Coffee" drink: 112 g beans per 4-demitasse espresso pot (~6 oz).
#  * net_weight_g 56 on the cinnamon + turmeric stock items once Schema
#    Compare has added the column (otherwise reported as pending).
# Rows are backed up (private JSON) before any change; backup failure aborts.

use strict;
use warnings;
use Comserv::Util::HealthKitchen::Backup;

our %MORNING_G = ( cinnamon => 16, turmeric => 16, chia => 58, collagen => 78 );
our %NET_G     = ( cinnamon => 56, turmeric => 56 );
our $COFFEE_G  = 112;

sub _key_for {
    my $n = lc( $_[1] // '' );
    for my $k (qw(cinnamon turmeric chia collagen pepper)) { return $k if index( $n, $k ) >= 0 }
    return undef;
}

sub _owner {
    my ( $class, $c ) = @_;
    return ( $c->stash->{SiteName} || $c->session->{SiteName}, $c->session->{username} );
}

sub _site_item {
    my ( $class, $schema, $site, %q ) = @_;
    return eval {
        $schema->resultset('InventoryItem')->search( { 'me.sitename' => $site, %q }, { order_by => 'me.id', rows => 1 } )->first;
    };
}

sub plan {
    my ( $class, $c ) = @_;
    my $schema = $c->model('DBEncy');
    my ( $site, $user ) = $class->_owner($c);
    die "not logged in\n" unless $site && $user;
    my $mb = $schema->resultset('Recipe')->search(
        { 'me.name' => 'Morning beverage', 'me.sitename' => $site, 'me.username_of_poster' => $user },
        { order_by => 'me.id', rows => 1 } )->first;
    my $coffee = $schema->resultset('Recipe')->search(
        { 'me.name' => 'Coffee', 'me.sitename' => $site, 'me.username_of_poster' => $user },
        { rows => 1 } )->first;
    my @lines = $mb ? sort { ( $a->sort_order // 0 ) <=> ( $b->sort_order // 0 ) } $mb->lines->all : ();
    return { schema => $schema, site => $site, user => $user, mb => $mb, coffee => $coffee, lines => \@lines };
}

sub apply {
    my ( $class, $c, %o ) = @_;
    my $p = eval { $class->plan($c) } or return { ok => 0, error => 'Could not read recipes.' };
    return { ok => 0, error => 'No "Morning beverage" recipe of yours on this site.' } unless $p->{mb};
    my ( $schema, $site, $user ) = @$p{qw(schema site user)};
    my @changes;
    my @pending;

    my %item_ids;
    for my $ln ( @{ $p->{lines} } ) {
        my $k = $class->_key_for( $ln->name_raw );
        $item_ids{$k} = $ln->inventory_item_id if $k && $NET_G{$k} && $ln->inventory_item_id;
    }
    my @items = grep { defined } map { $class->_site_item( $schema, $site, 'me.id' => $_ ) } values %item_ids;
    # Probe for the column without dereferencing it: the search itself dies when
    # inventory_items.net_weight_g does not exist yet (schema-compare not run).
    my $net_col = eval { $schema->resultset('InventoryItem')->search( {}, { columns => ['net_weight_g'], rows => 1 } )->first; 1 };

    my $bk = Comserv::Util::HealthKitchen::Backup->write( 'recipe_setup', {
        recipe => Comserv::Util::HealthKitchen::Backup->rows( $p->{mb}, ( $p->{coffee} ? $p->{coffee} : () ) ),
        lines  => Comserv::Util::HealthKitchen::Backup->rows( @{ $p->{lines} } ),
        ( $net_col ? ( items => Comserv::Util::HealthKitchen::Backup->rows(@items) ) : () ),
    }, dir => $o{backup_dir} );

    $schema->txn_do( sub {
        my $has_collagen;
        my $ord = 0;
        for my $ln ( @{ $p->{lines} } ) {
            $ord = $ln->sort_order if ( $ln->sort_order // 0 ) > $ord;
            my $k = $class->_key_for( $ln->name_raw ) or next;
            $has_collagen = 1 if $k eq 'collagen';
            my %want = $k eq 'pepper'
                ? ( quantity => undef, unit => undef, quantity_text => 'pinch' )
                : ( quantity => $MORNING_G{$k}, unit => 'g', quantity_text => undef );
            my %upd = map { $_ => $want{$_} } grep {
                my $cur = $ln->get_column($_);
                ( defined $cur xor defined $want{$_} ) || ( defined $cur && ( $_ eq 'quantity' ? $cur + 0 != $want{$_} : $cur ne $want{$_} ) )
            } keys %want;
            next unless %upd;
            $ln->update( \%upd );
            push @changes, "Morning beverage: " . $ln->name_raw . ' -> ' . ( $k eq 'pepper' ? 'pinch (not deducted)' : "$MORNING_G{$k} g" );
        }
        unless ($has_collagen) {
            my $item = $class->_site_item( $schema, $site, -or => [ 'me.sku' => 'HK-COLLAGEN-ORG', 'me.name' => { like => '%ollagen%' } ] );
            $schema->resultset('RecipeLine')->create( {
                recipe_id => $p->{mb}->id, sort_order => $ord + 1,
                ingredient_source => $item ? 'inventory' : 'ad_hoc', inventory_item_id => $item ? $item->id : undef,
                name_raw => 'Collagen', quantity => $MORNING_G{collagen}, unit => 'g', process_step => 'prep' } );
            push @changes, "Morning beverage: added Collagen $MORNING_G{collagen} g" . ( $item ? '' : ' (no stock item linked)' );
        }
        unless ( $p->{coffee} ) {
            my $item = $class->_site_item( $schema, $site, 'me.sku' => 'HK-COFFEE-BEANS' );
            my $r = $schema->resultset('Recipe')->create( {
                name => 'Coffee', recipe_kind => 'food_recipe', recipe_code => 'HK-COFFEE-HOME',
                description => 'Home coffee: one 4-demitasse espresso pot (~6 oz).',
                preparation => "Brew a 4-demitasse espresso pot with $COFFEE_G g of beans.",
                yield_amount => 6, yield_unit => 'oz', servings => 1,
                sitename => $site, status => 'active', username_of_poster => $user, source => 'Health Kitchen setup' } );
            $schema->resultset('RecipeLine')->create( {
                recipe_id => $r->id, sort_order => 1,
                ingredient_source => $item ? 'inventory' : 'ad_hoc', inventory_item_id => $item ? $item->id : undef,
                name_raw => 'Coffee beans', quantity => $COFFEE_G, unit => 'g', process_step => 'prep' } );
            push @changes, "Created Coffee drink recipe ($COFFEE_G g beans)";
        }
        if ($net_col) {
            for my $k ( sort keys %item_ids ) {
                my ($it) = grep { $_->id == $item_ids{$k} } @items or next;
                next if defined $it->net_weight_g && $it->net_weight_g + 0 == $NET_G{$k};
                $it->update( { net_weight_g => $NET_G{$k} } );
                push @changes, "Item " . $it->id . " net_weight_g = $NET_G{$k}";
            }
        }
    } );
    push @pending, 'net_weight_g on items ' . join( ', ', sort values %item_ids ) . ': run Schema Compare for InventoryItem, then Apply again'
        unless $net_col;
    return { ok => 1, changes => \@changes, pending => \@pending, backup => $bk };
}

1;
