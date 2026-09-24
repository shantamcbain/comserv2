package Comserv::Util::HealthKitchen;
use Moose;
use namespace::autoclean;
use Try::Tiny;
use POSIX qw(strftime);
use Comserv::Util::Logging;

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance },
);

# Two pantry modes (D6):
#   inventory  — site_modules inventory|accounting enabled. Mark-made deducts
#                inventory_items so /Inventory/purchase short list can reorder.
#   personal   — Health Kitchen only. Mark-made deducts hk_user_pantry_qty.
#                Short list is this util, not AP invoices / mail classifier.

sub site_has_inventory {
    my ( $self, $c ) = @_;
    my $em = $c->stash->{enabled_modules} || {};
    return 0 unless ref $em eq 'HASH';
    return 1 if $em->{inventory} || $em->{Inventory};
    return 1 if $em->{accounting} || $em->{Accounting};
    return 0;
}

sub source_ok {
    my ( $self, $schema, $source ) = @_;
    return 0 unless $schema && $source;
    my $ok = 0;
    try {
        $ok = $schema->source($source) ? 1 : 0;
    }
    catch {
        $ok = 0;
    };
    return $ok;
}

sub table_ready {
    my ( $self, $c, $source ) = @_;
    my $schema = eval { $c->model('DBEncy') };
    return 0 unless $schema && $self->source_ok( $schema, $source );
    my $ready = 0;
    try {
        $schema->resultset($source)->search( {}, { rows => 1 } )->count;
        $ready = 1;
    }
    catch {
        my $err = $_;
        $self->logging->log_with_details( $c, 'warning', __FILE__, __LINE__, 'table_ready',
            "Health Kitchen source $source not ready: $err" );
        $ready = 0;
    };
    return $ready;
}

sub pantry_ready {
    my ( $self, $c ) = @_;
    return $self->table_ready( $c, 'HealthKitchen::UserPantryQty' );
}

sub recipe_ready {
    my ( $self, $c ) = @_;
    return $self->table_ready( $c, 'Recipe' )
        && $self->table_ready( $c, 'RecipeLine' );
}

sub sitename {
    my ( $self, $c ) = @_;
    return $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC';
}

sub list_pantry {
    my ( $self, $c ) = @_;
    my @rows;

    # Site with inventory: household stock IS inventory_items (food/consumable).
    # Overlay table is extra personal qty, not the only pantry.
    if ( $self->site_has_inventory($c) ) {
        push @rows, @{ $self->list_inventory_foods($c) };
    }

    if ( $self->pantry_ready($c) ) {
        my %seen_id   = map { ( $_->{inventory_item_id} || 0 ) => 1 } @rows;
        my %seen_name = map { lc( $_->{name} // '' ) => 1 } @rows;
        try {
            my $rs = $c->model('DBEncy')->resultset('HealthKitchen::UserPantryQty')->search(
                {
                    user_id  => $c->session->{user_id},
                    sitename => $self->sitename($c),
                },
                { order_by => 'name' }
            );
            while ( my $row = $rs->next ) {
                my $h = $self->_pantry_row_hash($row);
                $h->{via} = 'pantry';
                next if $h->{inventory_item_id} && $seen_id{ $h->{inventory_item_id} };
                next if $seen_name{ lc( $h->{name} // '' ) };
                push @rows, $h;
            }
        }
        catch {
            $self->logging->log_with_details( $c, 'error', __FILE__, __LINE__, 'list_pantry',
                "list_pantry overlay failed: $_" );
        };
    }
    return \@rows;
}

sub list_inventory_foods {
    my ( $self, $c ) = @_;
    my @food;
    my @all;
    try {
        my $rs = $c->model('DBEncy')->resultset('InventoryItem')->search(
            {
                sitename => $self->sitename($c),
                status   => 'active',
            },
            { prefetch => 'stock_levels', order_by => 'name' }
        );
        while ( my $item = $rs->next ) {
            my $on = 0;
            $on += ( $_->quantity_on_hand || 0 ) for $item->stock_levels;
            my $row = {
                id                => undef,
                name              => $item->name,
                sku               => $item->sku,
                qty               => $on,
                unit              => $item->unit_of_measure || 'each',
                reorder_point     => 0 + ( $item->reorder_point // 0 ),
                inventory_item_id => $item->id,
                notes             => $item->notes,
                via               => 'inventory',
                category          => $item->category,
            };
            push @all, $row;
            push @food, $row if $self->_looks_like_food($item);
        }
    }
    catch {
        $self->logging->log_with_details( $c, 'error', __FILE__, __LINE__, 'list_inventory_foods',
            "list_inventory_foods failed: $_" );
    };

    # No food/consumable category yet (InventoryAccounting ticket still open):
    # show every active SKU rather than an empty pantry.
    return \@food if @food;
    return \@all;
}

sub _looks_like_food {
    my ( $self, $item ) = @_;
    my $cat = lc( $item->category // '' );
    return 1 if $cat =~ /food|herb|spice|produce|grocery|pantry|supplement|beverage|drink|tea|coffee|seed/;
    return 1 if $item->is_consumable;
    my $sku = uc( $item->sku // '' );
    return 1 if $sku =~ /^HK-/;
    return 0;
}

sub _pantry_row_hash {
    my ( $self, $row ) = @_;
    return {
        id                => $row->id,
        name              => $row->name,
        qty               => 0 + ( $row->qty // 0 ),
        unit              => $row->unit,
        reorder_point     => 0 + ( $row->reorder_point // 0 ),
        inventory_item_id => $row->inventory_item_id,
        notes             => $row->notes,
    };
}

sub add_pantry_item {
    my ( $self, $c, $args ) = @_;
    return { ok => 0, error => 'Pantry tables are not created yet. Run schema-compare.' }
        unless $self->pantry_ready($c);

    my $name = $args->{name} // '';
    $name =~ s/^\s+|\s+$//g;
    return { ok => 0, error => 'Name is required.' } unless length $name;

    my $qty  = $args->{qty};
    $qty = 0 unless defined $qty && $qty =~ /^-?\d+(\.\d+)?$/;
    my $unit = $args->{unit} || 'each';
    my $rp   = $args->{reorder_point};
    $rp = 0 unless defined $rp && $rp =~ /^-?\d+(\.\d+)?$/;
    my $item_id = $args->{inventory_item_id};
    $item_id = undef unless $item_id && $item_id =~ /^\d+$/;

    my $row;
    try {
        $row = $c->model('DBEncy')->resultset('HealthKitchen::UserPantryQty')->update_or_create(
            {
                user_id           => $c->session->{user_id},
                sitename          => $self->sitename($c),
                name              => $name,
                qty               => $qty,
                unit              => $unit,
                reorder_point     => $rp,
                inventory_item_id => $item_id,
                notes             => $args->{notes},
            },
            { key => 'hk_pantry_user_name' }
        );
    }
    catch {
        $self->logging->log_with_details( $c, 'error', __FILE__, __LINE__, 'add_pantry_item',
            "add_pantry_item failed: $_" );
        return;
    };
    return { ok => 0, error => 'Could not save pantry item.' } unless $row;
    return { ok => 1, row => $self->_pantry_row_hash($row) };
}

sub list_recipes {
    my ( $self, $c ) = @_;
    return [] unless $self->recipe_ready($c);
    my @out;
    try {
        my $rs = $c->model('DBEncy')->resultset('Recipe')->search(
            {
                sitename           => $self->sitename($c),
                username_of_poster => $c->session->{username},
                recipe_kind        => 'food_recipe',
                status             => { '!=' => 'archived' },
            },
            { order_by => 'name', prefetch => 'lines' }
        );
        while ( my $r = $rs->next ) {
            push @out, $self->_recipe_hash($r);
        }
    }
    catch {
        $self->logging->log_with_details( $c, 'error', __FILE__, __LINE__, 'list_recipes',
            "list_recipes failed: $_" );
    };
    return \@out;
}

sub _recipe_hash {
    my ( $self, $r ) = @_;
    my @lines;
    for my $ln ( $r->lines ) {
        push @lines, {
            id                => $ln->id,
            name              => $ln->name_raw,
            quantity          => $ln->quantity,
            unit              => $ln->unit,
            ingredient_source => $ln->ingredient_source,
            inventory_item_id => $ln->inventory_item_id,
            herb_id           => $ln->herb_id,
            notes             => $ln->notes,
        };
    }
    return {
        id          => $r->id,
        recipe_code => $r->recipe_code,
        name        => $r->name,
        preparation => $r->preparation,
        instructions => $r->instructions,
        yield_amount => $r->yield_amount,
        yield_unit   => $r->yield_unit,
        lines        => \@lines,
    };
}

sub consume_recipe {
    my ( $self, $c, $recipe_id, $batches ) = @_;
    $batches ||= 1;
    return { ok => 0, error => 'Recipe tables are not created yet. Run schema-compare.' }
        unless $self->recipe_ready($c);
    return { ok => 0, error => 'Invalid recipe.' }
        unless $recipe_id && $recipe_id =~ /^\d+$/;

    my $recipe = eval {
        $c->model('DBEncy')->resultset('Recipe')->search(
            {
                id                 => $recipe_id,
                sitename           => $self->sitename($c),
                username_of_poster => $c->session->{username},
            },
            { prefetch => 'lines' }
        )->single;
    };
    if ( my $err = $@ ) {
        $self->logging->log_with_details( $c, 'error', __FILE__, __LINE__, 'consume_recipe',
            "recipe load failed: $err" );
        return { ok => 0, error => 'Could not load recipe.' };
    }
    return { ok => 0, error => 'Recipe not found.' } unless $recipe;

    my $use_inv = $self->site_has_inventory($c);
    my @deducted;
    my @skipped;
    my $ok = 1;
    for my $ln ( $recipe->lines ) {
        my $qty = $ln->quantity;
        unless ( defined $qty && $qty > 0 ) {
            push @skipped, { name => $ln->name_raw, reason => 'no numeric quantity' };
            next;
        }
        my $need = $qty * $batches;
        my $name = $ln->name_raw || 'ingredient';
        if ( $use_inv && $ln->inventory_item_id ) {
            my $res = $self->_deduct_inventory( $c, $ln->inventory_item_id, $need, $recipe, $name );
            if ( $res->{ok} ) {
                push @deducted, { name => $name, qty => $need, unit => $ln->unit, via => 'inventory' };
            }
            else {
                $ok = 0;
                push @skipped, { name => $name, reason => $res->{error} || 'inventory deduct failed' };
            }
        }
        else {
            my $res = $self->_deduct_pantry( $c, $name, $need, $ln->unit );
            if ( $res->{ok} ) {
                push @deducted, { name => $name, qty => $need, unit => $ln->unit, via => 'pantry' };
            }
            else {
                $ok = 0;
                push @skipped, { name => $name, reason => $res->{error} || 'pantry deduct failed' };
            }
        }
    }

    $self->logging->log_with_details( $c, 'info', __FILE__, __LINE__, 'consume_recipe',
        'Marked recipe ' . $recipe->id . " made x$batches inventory=" . ( $use_inv ? 1 : 0 ) );

    return {
        ok       => $ok || ( @deducted ? 1 : 0 ),
        deducted => \@deducted,
        skipped  => \@skipped,
        via      => $use_inv ? 'inventory' : 'pantry',
        name     => $recipe->name,
    };
}

sub _deduct_inventory {
    my ( $self, $c, $item_id, $need, $recipe, $name ) = @_;
    my $schema   = $c->model('DBEncy');
    my $sitename = $self->sitename($c);
    my $now      = strftime( '%Y-%m-%d %H:%M:%S', localtime );
    my $err;
    my $ok = 0;
    try {
        my $sl_rs = $schema->resultset('InventoryStockLevel')->search(
            { item_id => $item_id },
            { order_by => 'id' }
        );
        my $remaining = $need;
        my $touched   = 0;
        while ( my $sl = $sl_rs->next ) {
            last if $remaining <= 0;
            my $have = 0 + ( $sl->quantity_on_hand // 0 );
            # Allow negative so the inventory short list sees the deficit.
            $sl->update( { quantity_on_hand => $have - $remaining, updated_at => $now } );
            $remaining = 0;
            $touched   = 1;
            last;
        }
        if ($touched) {
            $schema->resultset('InventoryTransaction')->create(
                {
                    item_id          => $item_id,
                    sitename         => $sitename,
                    transaction_type => 'use',
                    quantity         => $need,
                    reference_number => $recipe->recipe_code || ( 'HK-' . $recipe->id ),
                    notes            => 'Health Kitchen recipe: ' . ( $recipe->name || $name ),
                    performed_by     => $c->session->{username} || 'system',
                    transaction_date => $now,
                    created_at       => $now,
                }
            );
            $ok = 1;
        }
        else {
            $err = 'No stock row for this SKU. Receive it in Inventory first.';
        }
    }
    catch {
        $err = "$_";
        $self->logging->log_with_details( $c, 'error', __FILE__, __LINE__, '_deduct_inventory',
            "deduct inventory item $item_id failed: $err" );
    };
    return { ok => 0, error => $err || 'Inventory deduct failed.' } unless $ok;
    return { ok => 1 };
}

sub _deduct_pantry {
    my ( $self, $c, $name, $need, $unit ) = @_;
    return { ok => 0, error => 'Pantry tables are not created yet.' }
        unless $self->pantry_ready($c);
    my $row;
    my $err;
    try {
        $row = $c->model('DBEncy')->resultset('HealthKitchen::UserPantryQty')->search(
            {
                user_id  => $c->session->{user_id},
                sitename => $self->sitename($c),
                name     => $name,
            }
        )->single;
        if ($row) {
            my $have = 0 + ( $row->qty // 0 );
            $row->update( { qty => $have - $need } );
        }
        else {
            $err = "No pantry row named $name. Add it first.";
        }
    }
    catch {
        $err = "$_";
        $self->logging->log_with_details( $c, 'error', __FILE__, __LINE__, '_deduct_pantry',
            "pantry update failed: $err" );
    };
    return { ok => 0, error => $err } if $err || !$row;
    return { ok => 1 };
}

sub short_list {
    my ( $self, $c ) = @_;
    my @need;
    if ( $self->site_has_inventory($c) ) {
        try {
            require Comserv::Util::Inventory::Purchasing;
            my $p    = Comserv::Util::Inventory::Purchasing->new();
            my $list = $p->stock_reorder_list( $c, { sitename => $self->sitename($c) } );
            # Purchasing returns by_supplier + unassigned; flatten names if present.
            if ( ref $list eq 'HASH' ) {
                for my $it ( @{ $list->{unassigned} || [] } ) {
                    next unless ref $it eq 'HASH';
                    push @need, {
                        name => $it->{name} || $it->{sku},
                        via  => 'inventory',
                        qty  => $it->{short} || $it->{qty} || 0,
                    };
                }
                my $by = $list->{by_supplier} || [];
                $by = [ values %$by ] if ref $by eq 'HASH';
                for my $sup ( @$by ) {
                    next unless ref $sup eq 'HASH';
                    for my $it ( @{ $sup->{items} || [] } ) {
                        next unless ref $it eq 'HASH';
                        push @need, {
                            name => $it->{name} || $it->{sku},
                            via  => 'inventory',
                            qty  => $it->{short} || $it->{qty} || 0,
                        };
                    }
                }
            }
        }
        catch {
            $self->logging->log_with_details( $c, 'warning', __FILE__, __LINE__, 'short_list',
                "inventory short list unavailable: $_" );
        };
    }
    for my $row ( @{ $self->list_pantry($c) } ) {
        my $rp = $row->{reorder_point} || 0;
        my $q  = $row->{qty} || 0;
        if ( $q <= 0 || ( $rp > 0 && $q <= $rp ) ) {
            push @need, {
                name => $row->{name},
                via  => 'pantry',
                qty  => $q,
                unit => $row->{unit},
            };
        }
    }
    return \@need;
}

sub seed_morning_drink {
    my ( $self, $c ) = @_;
    return { ok => 0, error => 'Recipe tables are not created yet. Run schema-compare.' }
        unless $self->recipe_ready($c);

    my $schema   = $c->model('DBEncy');
    my $sitename = $self->sitename($c);
    my $user     = $c->session->{username};
    my $code     = 'HK-MORNING-01';

    my $existing = eval {
        $schema->resultset('Recipe')->search(
            { recipe_code => $code, sitename => $sitename }
        )->single;
    };
    if ( my $err = $@ ) {
        $self->logging->log_with_details( $c, 'error', __FILE__, __LINE__, 'seed_morning_drink',
            "seed lookup failed: $err" );
        return { ok => 0, error => 'Could not read recipes.' };
    }
    return { ok => 1, existed => 1, recipe_id => $existing->id } if $existing;

    my $use_inv = $self->site_has_inventory($c);
    my @lines   = (
        { name => 'Coffee beans (Votes Coffee Vernon)', qty => 15,   unit => 'g',   source => 'inventory', sku => 'HK-COFFEE-BEANS', cost => 13.00, uom => 'g' },
        { name => 'Turmeric',                            qty => 1,    unit => 'tsp', source => 'herb' },
        { name => 'Ceylon cinnamon',                     qty => 0.5,  unit => 'tsp', source => 'herb' },
        { name => 'Black pepper (ground)',               qty => 0.1,  unit => 'tsp', source => 'herb' },
        { name => 'Chia seed',                           qty => 1,    unit => 'tsp', source => 'ad_hoc' },
        { name => 'Organika enhanced collagen protein',  qty => 1,    unit => 'scoop', source => 'inventory', sku => 'HK-COLLAGEN-ORG', cost => undef, uom => 'scoop' },
    );

    my $recipe;
    try {
        $recipe = $schema->resultset('Recipe')->create(
            {
                recipe_code        => $code,
                name               => 'Morning turmeric coffee',
                recipe_kind        => 'food_recipe',
                description        => 'Daily pot: 4 demitasse, half the usual coffee, drink 2 cups. Votes Coffee Vernon beans ($65 / 5 lb). Pepper mill of whole pepper later replaces ground.',
                preparation        => 'Brew a 4-demitasse pot using half the normal coffee dose. Stir in turmeric, Ceylon cinnamon, a pinch of black pepper, chia, and one scoop of collagen. Drink two cups.',
                instructions       => 'Do not treat this as medical advice. Wellness kitchen only.',
                yield_amount       => 2,
                yield_unit         => 'cups',
                servings           => 1,
                sitename           => $sitename,
                status             => 'active',
                username_of_poster => $user,
                source             => 'Health Kitchen seed',
            }
        );
        my $ord = 0;
        for my $ln (@lines) {
            $ord++;
            my $item_id;
            if ( $use_inv && $ln->{sku} ) {
                $item_id = $self->_ensure_inventory_sku( $c, $ln );
            }
            my $src = $item_id ? 'inventory' : ( $ln->{source} eq 'herb' ? 'herb' : 'ad_hoc' );
            $schema->resultset('RecipeLine')->create(
                {
                    recipe_id         => $recipe->id,
                    sort_order        => $ord,
                    ingredient_source => $src,
                    inventory_item_id => $item_id,
                    name_raw          => $ln->{name},
                    quantity          => $ln->{qty},
                    unit              => $ln->{unit},
                    process_step      => 'prep',
                }
            );
            if ( $self->pantry_ready($c) ) {
                $self->add_pantry_item(
                    $c,
                    {
                        name              => $ln->{name},
                        qty               => 0,
                        unit              => $ln->{unit},
                        reorder_point     => 0,
                        inventory_item_id => $item_id,
                    }
                );
            }
        }
    }
    catch {
        $self->logging->log_with_details( $c, 'error', __FILE__, __LINE__, 'seed_morning_drink',
            "seed create failed: $_" );
        $recipe = undef;
    };
    return { ok => 0, error => 'Could not create the morning drink recipe.' } unless $recipe;
    return { ok => 1, existed => 0, recipe_id => $recipe->id };
}

sub _ensure_inventory_sku {
    my ( $self, $c, $ln ) = @_;
    my $schema   = $c->model('DBEncy');
    my $sitename = $self->sitename($c);
    my $item_id;
    try {
        my $item = $schema->resultset('InventoryItem')->search(
            { sku => $ln->{sku}, sitename => $sitename }
        )->single;
        if ( !$item ) {
            $item = $schema->resultset('InventoryItem')->create(
                {
                    sitename        => $sitename,
                    sku             => $ln->{sku},
                    name            => $ln->{name},
                    category        => 'food',
                    item_origin     => 'purchased',
                    unit_of_measure => $ln->{uom} || $ln->{unit} || 'each',
                    unit_cost       => $ln->{cost},
                    is_consumable   => 1,
                    is_reusable     => 0,
                    status          => 'active',
                    created_by      => $c->session->{username},
                }
            );
        }
        $item_id = $item->id if $item;
    }
    catch {
        $self->logging->log_with_details( $c, 'warning', __FILE__, __LINE__, '_ensure_inventory_sku',
            "SKU $ln->{sku} not created (inventory optional): $_" );
    };
    return $item_id;
}

__PACKAGE__->meta->make_immutable;
1;
