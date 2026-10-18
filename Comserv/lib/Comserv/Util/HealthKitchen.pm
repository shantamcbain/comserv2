package Comserv::Util::HealthKitchen;
use Moose;
use namespace::autoclean;
use Try::Tiny;
use POSIX qw(strftime);
use JSON qw(encode_json decode_json);

# Sourcing enums (see "Production / sourcing attributes" section).
our %SOURCING_ENUM = (
    food_category  => [qw(beef pork lamb chicken eggs dairy salmon fish_other leafy_greens berries apples
                          stone_fruit grapes potatoes tomatoes peppers corn soy grains legumes nuts other)],
    production     => [qw(organic_certified conventional transitional unknown)],
    animal_raising => [qw(grass_fed pasture feedlot free_range caged na)],
    catch_method   => [qw(wild farmed na)],
    gmo            => [qw(non_gmo_verified gmo unknown)],
);
our @SOURCING_COLS = ( keys(%SOURCING_ENUM), qw(local_km certifier cert_verified) );
our @PREF_COLS     = qw(prefer_organic avoid_feedlot ethics_weight);
our $LOCAL_KM      = 160;
our %RISK_PTS      = ( low => 0, med => 1, high => 2 );
our %BADGE = (
    organic_certified => 'Organic', conventional => 'Conventional', transitional => 'Transitional',
    grass_fed => 'Grass-fed', pasture => 'Pasture-raised', feedlot => 'Feedlot', free_range => 'Free-range',
    caged => 'Caged', wild => 'Wild', farmed => 'Farmed', non_gmo_verified => 'Non-GMO', gmo => 'GMO',
);
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

sub map_ready {
    my ( $self, $c ) = @_;
    return $self->table_ready( $c, 'HealthKitchen::InventoryEncyMap' );
}

sub symptom_ready {
    my ( $self, $c ) = @_;
    return $self->table_ready( $c, 'HealthKitchen::UserActiveSymptom' );
}

sub profile_ready {
    my ( $self, $c ) = @_;
    return $self->table_ready( $c, 'HealthKitchen::UserHealthProfile' );
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
    $self->_attach_ency_maps( $c, \@rows );
    return \@rows;
}

sub list_inventory_foods {
    my ( $self, $c ) = @_;
    my @food;
    my @all;
    try {
        my $rs = $c->model('DBEncy')->resultset('InventoryItem')->search(
            {
                "me.sitename" => $self->sitename($c),
                "me.status"   => 'active',
            },
            { prefetch => 'stock_levels', order_by => 'me.name' }
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
                barcode           => $item->barcode,
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

sub _attach_ency_maps {
    my ( $self, $c, $rows ) = @_;
    return unless $rows && @$rows && $self->map_ready($c);
    my @ids = grep { $_ } map { $_->{inventory_item_id} } @$rows;
    return unless @ids;
    my %by_item;
    try {
        my $rs = $c->model('DBEncy')->resultset('HealthKitchen::InventoryEncyMap')->search(
            {
                sitename          => $self->sitename($c),
                inventory_item_id => { -in => \@ids },
            }
        );
        while ( my $m = $rs->next ) {
            $by_item{ $m->inventory_item_id } = {
                herb_id     => $m->herb_id,
                organism_id => $m->organism_id,
                animal_id   => $m->animal_id,
                insect_id   => $m->insect_id,
                formula_id  => $m->formula_id,
            };
        }
    }
    catch {
        $self->logging->log_with_details( $c, 'warning', __FILE__, __LINE__, '_attach_ency_maps',
            "map attach failed: $_" );
    };
    for my $row (@$rows) {
        my $m = $by_item{ $row->{inventory_item_id} || 0 } || {};
        $row->{$_} = $m->{$_} for qw(herb_id organism_id animal_id insect_id formula_id);
    }
}

sub upsert_ency_map {
    my ( $self, $c, $args ) = @_;
    return { ok => 0, error => 'ENCY map table is not created yet. Run schema-compare.' }
        unless $self->map_ready($c);
    my $item_id = $args->{inventory_item_id};
    return { ok => 0, error => 'Inventory item id is required to link ENCY.' }
        unless $item_id && $item_id =~ /^\d+$/;
    my $clear = $args->{unlink} ? 1 : 0;
    my $row;
    try {
        my $rs = $c->model('DBEncy')->resultset('HealthKitchen::InventoryEncyMap');
        $row = $rs->search(
            { inventory_item_id => $item_id, sitename => $self->sitename($c) }
        )->single;
        my %vals = (
            inventory_item_id => $item_id,
            sitename          => $self->sitename($c),
            herb_id           => $clear ? undef : $self->_opt_id( $args->{herb_id} ),
            organism_id       => $clear ? undef : $self->_opt_id( $args->{organism_id} ),
            animal_id         => $clear ? undef : $self->_opt_id( $args->{animal_id} ),
            insect_id         => $clear ? undef : $self->_opt_id( $args->{insect_id} ),
            formula_id        => $clear ? undef : $self->_opt_id( $args->{formula_id} ),
        );
        if ($row) {
            $row->update( \%vals );
        }
        else {
            $row = $rs->create( \%vals );
        }
    }
    catch {
        $self->logging->log_with_details( $c, 'error', __FILE__, __LINE__, 'upsert_ency_map',
            "upsert_ency_map failed: $_" );
        $row = undef;
    };
    return { ok => 0, error => 'Could not save ENCY link.' } unless $row;
    return { ok => 1 };
}

sub _opt_id {
    my ( $self, $v ) = @_;
    return undef unless defined $v && $v =~ /^\d+$/;
    return 0 + $v;
}

sub list_ency_symptoms {
    my ( $self, $c ) = @_;
    my @out;
    try {
        my $rs = $c->model('DBEncy')->resultset('Ency::Symptom')->search(
            {},
            { order_by => 'name', rows => 400, columns => [qw(record_id name common_name)] }
        );
        while ( my $s = $rs->next ) {
            push @out, {
                id          => $s->record_id,
                name        => $s->name,
                common_name => $s->common_name,
            };
        }
    }
    catch {
        $self->logging->log_with_details( $c, 'warning', __FILE__, __LINE__, 'list_ency_symptoms',
            "list_ency_symptoms failed: $_" );
    };
    return \@out;
}

sub list_active_symptoms {
    my ( $self, $c ) = @_;
    return [] unless $self->symptom_ready($c);
    my @out;
    try {
        my $rs = $c->model('DBEncy')->resultset('HealthKitchen::UserActiveSymptom')->search(
            {
                "me.user_id"  => $c->session->{user_id},
                "me.sitename" => $self->sitename($c),
                "me.status"   => 'active',
            },
            { order_by => 'me.id', prefetch => 'symptom' }
        );
        while ( my $row = $rs->next ) {
            my $sym = eval { $row->symptom };
            push @out, {
                id         => $row->id,
                symptom_id => $row->symptom_id,
                name       => $sym ? ( $sym->name || $sym->common_name ) : '',
                severity   => $row->severity,
                status     => $row->status,
            };
        }
    }
    catch {
        $self->logging->log_with_details( $c, 'error', __FILE__, __LINE__, 'list_active_symptoms',
            "list_active_symptoms failed: $_" );
    };
    return \@out;
}

sub active_symptom_ids {
    my ( $self, $c ) = @_;
    return [ map { $_->{symptom_id} } @{ $self->list_active_symptoms($c) } ];
}

sub set_active_symptom {
    my ( $self, $c, $args ) = @_;
    return { ok => 0, error => 'Symptom table is not created yet. Run schema-compare.' }
        unless $self->symptom_ready($c);
    my $sid = $self->_opt_id( $args->{symptom_id} );
    return { ok => 0, error => 'Pick a symptom.' } unless $sid;
    my $row;
    try {
        my $rs = $c->model('DBEncy')->resultset('HealthKitchen::UserActiveSymptom');
        $row = $rs->search(
            {
                user_id    => $c->session->{user_id},
                sitename   => $self->sitename($c),
                symptom_id => $sid,
            }
        )->single;
        if ($row) {
            $row->update(
                {
                    status      => 'active',
                    severity    => $args->{severity},
                    resolved_at => undef,
                }
            );
        }
        else {
            $row = $rs->create(
                {
                    user_id    => $c->session->{user_id},
                    sitename   => $self->sitename($c),
                    symptom_id => $sid,
                    severity   => $args->{severity},
                    status     => 'active',
                }
            );
        }
    }
    catch {
        $self->logging->log_with_details( $c, 'error', __FILE__, __LINE__, 'set_active_symptom',
            "set_active_symptom failed: $_" );
        $row = undef;
    };
    return { ok => 0, error => 'Could not save symptom.' } unless $row;
    return { ok => 1 };
}

sub resolve_symptom {
    my ( $self, $c, $id ) = @_;
    return { ok => 0, error => 'Symptom table is not created yet. Run schema-compare.' }
        unless $self->symptom_ready($c);
    $id = $self->_opt_id($id);
    return { ok => 0, error => 'Missing symptom row.' } unless $id;
    my $ok;
    try {
        my $row = $c->model('DBEncy')->resultset('HealthKitchen::UserActiveSymptom')->search(
            {
                id       => $id,
                user_id  => $c->session->{user_id},
                sitename => $self->sitename($c),
            }
        )->single;
        if ($row) {
            $row->update( { status => 'resolved', resolved_at => strftime( '%Y-%m-%d %H:%M:%S', gmtime ) } );
            $ok = 1;
        }
    }
    catch {
        $self->logging->log_with_details( $c, 'error', __FILE__, __LINE__, 'resolve_symptom',
            "resolve_symptom failed: $_" );
    };
    return { ok => 0, error => 'Could not resolve symptom.' } unless $ok;
    return { ok => 1 };
}

sub save_profile {
    my ( $self, $c, $args ) = @_;
    return { ok => 0, error => 'Profile table is not created yet. Run schema-compare.' }
        unless $self->profile_ready($c);
    my %data = (
        diet_flags => $args->{diet_flags},
        allergies  => $self->_enc( $args->{allergies} ),
        goals      => $args->{goals},
    );
    my $prefs_ok = $self->prefs_cols_ready($c);
    if ( $prefs_ok && grep { exists $args->{$_} } @PREF_COLS, 'prefs_submitted' ) {
        my ( $p, $err ) = $self->validate_prefs($args);
        return { ok => 0, error => $err } if $err;
        %data = ( %data, %$p );
    }
    my $row;
    try {
        my $rs  = $c->model('DBEncy')->resultset('HealthKitchen::UserHealthProfile');
        my %key = ( user_id => $c->session->{user_id}, sitename => $self->sitename($c) );
        $row = $rs->search( \%key, ( $prefs_ok ? {} : { columns => $self->_base_cols( $c, 'HealthKitchen::UserHealthProfile', \@PREF_COLS ) } ) )->single;
        if ($row) { $row->update( \%data ) }
        else      { $row = $rs->create( { %key, %data } ) }
    }
    catch {
        $self->logging->log_with_details( $c, 'error', __FILE__, __LINE__, 'save_profile',
            "save_profile failed: $_" );
        $row = undef;
    };
    return { ok => 0, error => 'Could not save profile.' } unless $row;
    return { ok => 1 };
}

sub get_profile {
    my ( $self, $c ) = @_;
    return {} unless $self->profile_ready($c);
    my $h = {};
    try {
        my $row = $c->model('DBEncy')->resultset('HealthKitchen::UserHealthProfile')->search(
            { user_id => $c->session->{user_id}, sitename => $self->sitename($c) },
            ( $self->prefs_cols_ready($c) ? {} : { columns => $self->_base_cols( $c, 'HealthKitchen::UserHealthProfile', \@PREF_COLS ) } )
        )->single;
        if ($row) {
            $h = {
                diet_flags => $row->diet_flags,
                allergies  => $self->_dec( $row->allergies ),
                goals      => $row->goals,
            };
            if ( $self->prefs_cols_ready($c) ) {
                $h->{$_} = $row->get_column($_) for @PREF_COLS;
            }
        }
    }
    catch {
        $self->logging->log_with_details( $c, 'warning', __FILE__, __LINE__, 'get_profile',
            "get_profile failed: $_" );
    };
    return $h;
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
                "me.sitename" => $self->sitename($c),
                -or         => [ { "me.username_of_poster" => $c->session->{username} },
                                 { "me.source" => 'ai_generated' } ],
                "me.recipe_kind" => 'food_recipe',
                "me.status" => { '!=' => 'archived' },
            },
            { order_by => 'me.name', prefetch => 'lines' }
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
        status       => $r->status,
        source       => $r->source,
        notes        => $r->notes,
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
                "me.id" => $recipe_id,
                "me.sitename" => $self->sitename($c),
                "me.username_of_poster" => $c->session->{username},
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

# relationship_type values that mean "do not use for this symptom"
my %_SKIP_REL = map { $_ => 1 } qw(
    contra contraindicated contraindication avoid worsens aggravates caution
    do_not_use not_for
);

sub _rel_skip {
    my ( $self, $type ) = @_;
    return 0 unless defined $type && length $type;
    my $lc = lc $type;
    $lc =~ s/[\s\-]+/_/g;
    return 1 if $_SKIP_REL{$lc};
    return 1 if $lc =~ /contra|avoid|worsen|aggravat/;
    return 0;
}

sub _id_set {
    my ( $self, $list ) = @_;
    my %set;
    for my $v ( @{ $list || [] } ) {
        next unless defined $v && $v =~ /^\d+$/;
        $set{ 0 + $v } = 1;
    }
    return \%set;
}

# Pure matcher (no Catalyst, no LLM). Inject a dataset for tests.
# pantry_herb_ids drives "herbs" (in stock). ENCY links outside the pantry go to
# "not_in_pantry" as hints only; formulas still require every herb in stock.
sub match_candidates {
    my ( $self, $data ) = @_;
    $data ||= {};
    my $pantry = $self->_id_set( $data->{pantry_herb_ids} );
    my $syms   = $self->_id_set( $data->{symptom_ids} );
    my $drugs  = $self->_id_set( $data->{user_drug_ids} );
    my $herbs  = $data->{herbs} || {};

    # History conditions (ENCY DiseaseHerb) become extra candidate links, gated like symptom links.
    my @links = @{ $data->{herb_symptoms} || [] };
    my $dis = $self->_id_set( $data->{disease_ids} );
    for my $dh ( @{ $data->{disease_herbs} || [] } ) {
        next unless ref $dh eq 'HASH' && $dh->{herb_id} && $dh->{disease_id} && $dis->{ 0 + $dh->{disease_id} };
        push @links, { herb_id => $dh->{herb_id}, symptom_id => 0, disease_id => $dh->{disease_id},
                       relationship_type => $dh->{relationship_type} // 'history_condition' };
    }
    my @herb_out;
    my @missing_out;
    my %seen_missing;
    my %ok_herb;
    for my $link (@links) {
        next unless ref $link eq 'HASH';
        my $hid = $link->{herb_id};
        my $sid = $link->{symptom_id};
        next unless $hid && ( $link->{disease_id} || ( $sid && $syms->{ 0 + $sid } ) );
        next if $self->_rel_skip( $link->{relationship_type} );
        my $h = $herbs->{$hid} || $herbs->{ 0 + $hid } || {};
        unless ( $pantry->{ 0 + $hid } ) {
            # ENCY-linked but not in stock: shown as a "not in pantry" hint only.
            next if $seen_missing{ 0 + $hid }++;
            push @missing_out, {
                herb_id            => 0 + $hid,
                name               => $h->{name} || $h->{common_names} || $h->{botanical_name} || '',
                symptom_id         => 0 + ( $sid || 0 ),
                disease_id         => $link->{disease_id},
                relationship_type  => $link->{relationship_type},
                contra_indications => $h->{contra_indications} || '',
            };
            next;
        }
        my @terms = grep { defined && length } ( $data->{user_contra_term}, @{ $data->{user_contra_terms} || [] } );
        if (@terms) {
            my $ci = lc( $h->{contra_indications} // '' );
            next if length $ci && grep { index( $ci, lc $_ ) >= 0 } @terms;
        }
        my $blocked;
        for my $dh ( @{ $data->{drug_herb} || [] } ) {
            next unless ref $dh eq 'HASH';
            next unless $dh->{herb_id} && ( 0 + $dh->{herb_id} ) == ( 0 + $hid );
            next unless $dh->{drug_id} && $drugs->{ 0 + $dh->{drug_id} };
            $blocked = 1;
            last;
        }
        next if $blocked;
        next if $ok_herb{ 0 + $hid };
        $ok_herb{ 0 + $hid } = 1;
        push @herb_out, {
            herb_id            => 0 + $hid,
            name               => $h->{name} || $h->{common_names} || $h->{botanical_name} || '',
            symptom_id         => 0 + ( $sid || 0 ),
            disease_id         => $link->{disease_id},
            relationship_type  => $link->{relationship_type},
            contra_indications => $h->{contra_indications} || '',
        };
    }

    my @formula_out;
    for my $f ( @{ $data->{formulas} || [] } ) {
        next unless ref $f eq 'HASH';
        my @fherbs = grep { defined $_ && $_ =~ /^\d+$/ } @{ $f->{herb_ids} || [] };
        next unless @fherbs;
        my $all_in = 1;
        for my $hid (@fherbs) {
            unless ( $pantry->{ 0 + $hid } && $ok_herb{ 0 + $hid } ) {
                $all_in = 0;
                last;
            }
        }
        next unless $all_in;
        push @formula_out, {
            formula_id => $f->{id} || $f->{formula_id},
            name       => $f->{name} || '',
            herb_ids   => [ map { 0 + $_ } @fherbs ],
        };
    }

    return {
        herbs         => \@herb_out,
        formulas      => \@formula_out,
        not_in_pantry => \@missing_out,
    };
}

# Live DB path. Returns empty sets if tables or pantry mapping are missing.
sub match_for_symptoms {
    my ( $self, $c, $opts ) = @_;
    $opts ||= {};
    return $self->match_candidates( $opts->{dataset} ) if $opts->{dataset};

    my $symptom_ids = $opts->{symptom_ids} || [];
    $symptom_ids = [$symptom_ids] unless ref $symptom_ids eq 'ARRAY';
    my $hist = $opts->{history_inputs} || eval { $self->user_matching_inputs($c) } || {};
    unless ( @$symptom_ids || @{ $hist->{disease_ids} || [] } ) {
        return { herbs => [], formulas => [], error => 'no_symptoms' };
    }

    my $dataset = {
        symptom_ids       => $symptom_ids,
        pantry_herb_ids   => $self->_pantry_herb_ids($c),
        user_drug_ids     => [ @{ $opts->{user_drug_ids} || [] }, @{ $hist->{drug_ids} || [] } ],
        user_contra_term  => $opts->{user_contra_term},
        user_contra_terms => $hist->{contra_terms} || [],
        disease_ids       => $hist->{disease_ids} || [],
        disease_herbs     => [],
        herb_symptoms     => [],
        herbs             => {},
        formulas          => [],
        drug_herb         => [],
    };

    my $schema = eval { $c->model('DBEncy') };
    return { herbs => [], formulas => [], error => 'no_schema' } unless $schema;

    try {
        if ( $self->source_ok( $schema, 'Ency::HerbSymptom' ) ) {
            my $rs = $schema->resultset('Ency::HerbSymptom')->search(
                { symptom_id => { -in => $symptom_ids } }
            );
            while ( my $row = $rs->next ) {
                push @{ $dataset->{herb_symptoms} }, {
                    herb_id           => $row->herb_id,
                    symptom_id        => $row->symptom_id,
                    relationship_type => $row->relationship_type,
                };
            }
        }
        # Fallback: herb_symptom is often unpopulated. Match symptom names against
        # herb therapeutic_action / medical_uses text (flagged relationship 'text_match').
        if ( !@{ $dataset->{herb_symptoms} }
            && $self->source_ok( $schema, 'Ency::Symptom' )
            && $self->source_ok( $schema, 'Ency::Herb' ) )
        {
            my @syms = $schema->resultset('Ency::Symptom')->search(
                { record_id => { -in => $symptom_ids } } )->all;
            for my $sym (@syms) {
                my @terms = grep { defined $_ && length($_) >= 3 }
                    ( $sym->name, $sym->common_name );
                next unless @terms;
                my @or;
                for my $t (@terms) {
                    ( my $like = $t ) =~ s/([%_\\])/\\$1/g;
                    push @or, { therapeutic_action => { -like => "%$like%" } },
                              { medical_uses       => { -like => "%$like%" } };
                }
                my $hrs = $schema->resultset('Ency::Herb')->search(
                    { -or => \@or }, { columns => ['record_id'], rows => 50 } );
                while ( my $h = $hrs->next ) {
                    push @{ $dataset->{herb_symptoms} }, {
                        herb_id           => $h->record_id,
                        symptom_id        => $sym->record_id,
                        relationship_type => 'text_match',
                    };
                }
            }
        }
        if ( @{ $dataset->{disease_ids} } && $self->source_ok( $schema, 'Ency::DiseaseHerb' ) ) {
            my $drs = $schema->resultset('Ency::DiseaseHerb')->search( { disease_id => { -in => $dataset->{disease_ids} } } );
            while ( my $d = $drs->next ) {
                push @{ $dataset->{disease_herbs} }, { herb_id => $d->herb_id, disease_id => $d->disease_id,
                                                       relationship_type => $d->relationship_type };
            }
        }
        my @hids = ( map( { $_->{herb_id} } @{ $dataset->{herb_symptoms} } ), map( { $_->{herb_id} } @{ $dataset->{disease_herbs} } ) );
        if ( @hids && $self->source_ok( $schema, 'Ency::Herb' ) ) {
            my $hrs = $schema->resultset('Ency::Herb')->search(
                { record_id => { -in => \@hids } }
            );
            while ( my $h = $hrs->next ) {
                $dataset->{herbs}{ $h->record_id } = {
                    name               => $h->common_names || $h->botanical_name,
                    botanical_name     => $h->botanical_name,
                    common_names       => $h->common_names,
                    contra_indications => $h->contra_indications,
                };
            }
        }
        if ( $self->source_ok( $schema, 'Ency::FormulaHerb' )
            && $self->source_ok( $schema, 'Ency::Formula' ) )
        {
            my %by_f;
            my $frs = $schema->resultset('Ency::FormulaHerb')->search({});
            while ( my $fh = $frs->next ) {
                next unless $fh->herb_id;
                push @{ $by_f{ $fh->formula_id } }, $fh->herb_id;
            }
            if (%by_f) {
                my $forms = $schema->resultset('Ency::Formula')->search(
                    { record_id => { -in => [ keys %by_f ] } }
                );
                while ( my $f = $forms->next ) {
                    my $fid = $f->can('record_id') ? $f->record_id : $f->id;
                    push @{ $dataset->{formulas} }, {
                        id       => $fid,
                        name     => $f->name,
                        herb_ids => $by_f{$fid} || $by_f{ $f->id } || [],
                    };
                }
            }
        }
        if ( @{ $dataset->{user_drug_ids} || [] }
            && $self->source_ok( $schema, 'Ency::DrugHerbInteraction' ) )
        {
            my $drs = $schema->resultset('Ency::DrugHerbInteraction')->search(
                { drug_id => { -in => $dataset->{user_drug_ids} } }
            );
            while ( my $d = $drs->next ) {
                push @{ $dataset->{drug_herb} }, {
                    herb_id => $d->herb_id,
                    drug_id => $d->drug_id,
                };
            }
        }
    }
    catch {
        $self->logging->log_with_details( $c, 'error', __FILE__, __LINE__, 'match_for_symptoms',
            "match_for_symptoms load failed: $_" );
    };

    return $self->match_candidates($dataset);
}

sub _pantry_herb_ids {
    my ( $self, $c ) = @_;
    my %ids;
    my $schema = eval { $c->model('DBEncy') };
    return [] unless $schema;
    try {
        my @item_ids;
        for my $row ( @{ $self->list_pantry($c) } ) {
            push @item_ids, $row->{inventory_item_id} if $row->{inventory_item_id};
            $ids{ 0 + $row->{herb_id} } = 1 if $row->{herb_id};
        }
        if ( @item_ids && $self->source_ok( $schema, 'HealthKitchen::InventoryEncyMap' ) ) {
            my $rs = $schema->resultset('HealthKitchen::InventoryEncyMap')->search(
                {
                    sitename          => $self->sitename($c),
                    inventory_item_id => { -in => \@item_ids },
                }
            );
            while ( my $m = $rs->next ) {
                $ids{ 0 + $m->herb_id } = 1 if $m->herb_id;
            }
        }
    }
    catch {
        $self->logging->log_with_details( $c, 'warning', __FILE__, __LINE__, '_pantry_herb_ids',
            "pantry herb map failed: $_" );
    };
    return [ sort { $a <=> $b } keys %ids ];
}


# ── Meal plans (inventory-first) ───────────────────────────────────────────

sub meal_plan_ready {
    my ( $self, $c ) = @_;
    return $self->table_ready( $c, 'HealthKitchen::MealPlan' )
        && $self->table_ready( $c, 'HealthKitchen::MealPlanEntry' );
}

sub _ingredient_key {
    my ( $self, $line ) = @_;
    return 'inv:' . $line->{inventory_item_id} if $line->{inventory_item_id};
    my $n = lc( $line->{name} // '' );
    $n =~ s/^\s+|\s+$//g;
    $n =~ s/\s+/ /g;
    return length $n ? "name:$n" : undef;
}

# Pure: sum recipe line needs for planned entries and compare with stock.
# $entries: [ { servings, recipe => { yield_amount, lines => [ {name,quantity,unit,inventory_item_id} ] } } ]
# $pantry:  list_pantry rows ({name, qty, unit, inventory_item_id})
# Returns { have => [...], buy => [...] } — buy is ONLY the shortfall after stock.
sub plan_requirements {
    my ( $self, $entries, $pantry ) = @_;
    my ( %need, @order );
    for my $e ( @{ $entries || [] } ) {
        my $r = $e->{recipe} or next;
        my $yield = ( $r->{yield_amount} && $r->{yield_amount} > 0 ) ? $r->{yield_amount} : 1;
        my $factor = ( $e->{servings} || 1 ) / $yield;
        for my $ln ( @{ $r->{lines} || [] } ) {
            my $key = $self->_ingredient_key($ln) or next;
            unless ( $need{$key} ) {
                push @order, $key;
                $need{$key} = { name => $ln->{name}, unit => $ln->{unit} // '',
                                inventory_item_id => $ln->{inventory_item_id}, need => 0 };
            }
            $need{$key}{need} += ( $ln->{quantity} || 0 ) * $factor;
        }
    }
    my %stock;
    for my $p ( @{ $pantry || [] } ) {
        for my $key ( grep { defined } (
                $p->{inventory_item_id} ? 'inv:' . $p->{inventory_item_id} : undef,
                $self->_ingredient_key( { name => $p->{name} } ) ) )
        {
            $stock{$key} ||= { qty => 0, unit => $p->{unit} // '' };
            $stock{$key}{sourcing} ||= $p->{product}{badges} if $p->{product} && $p->{product}{badges} && @{ $p->{product}{badges} };
            $stock{$key}{score} //= $p->{product}{score} if $p->{product};
            $stock{$key}{qty} += $p->{qty} || 0;
        }
    }
    my ( @have, @buy );
    for my $key (@order) {
        my $n  = $need{$key};
        my $st = $stock{$key} || ( $n->{name} ? $stock{ $self->_ingredient_key( { name => $n->{name} } ) // '' } : undef );
        my $on = $st ? $st->{qty} : 0;
        my $row = { %$n, need => 0 + sprintf( '%.2f', $n->{need} ), on_hand => 0 + $on };
        $row->{sourcing} = $st->{sourcing} if $st && $st->{sourcing};
        $row->{score}    = $st->{score}    if $st && defined $st->{score};
        if ( $st && length $n->{unit} && length $st->{unit} && lc $n->{unit} ne lc $st->{unit} ) {
            $row->{unit_mismatch} = $st->{unit};    # can't compare; list as have, flag for review
            push @have, $row;
            next;
        }
        my $short = $n->{need} - $on;
        if ( $short > 0.0001 ) {
            $row->{buy} = 0 + sprintf( '%.2f', $short );
            push @buy, $row;
        }
        else {
            push @have, $row;
        }
    }
    return { have => \@have, buy => \@buy };
}

# Pure: rank recipes by share of ingredient lines already in stock (inventory-first).
sub rank_recipes_by_stock {
    my ( $self, $recipes, $pantry ) = @_;
    my @out;
    for my $r ( @{ $recipes || [] } ) {
        my $req = $self->plan_requirements( [ { servings => $r->{yield_amount} || 1, recipe => $r } ], $pantry );
        my $total = @{ $req->{have} } + @{ $req->{buy} };
        next unless $total;
        my @sc = map { $_->{score} } grep { defined $_->{score} } @{ $req->{have} }, @{ $req->{buy} };
        my $score = @sc ? eval { my $t = 0; $t += $_ for @sc; $t / @sc } : 0;
        push @out, { id => $r->{id}, name => $r->{name}, in_stock => scalar @{ $req->{have} },
                     total => $total, missing => [ map { $_->{name} } @{ $req->{buy} } ],
                     sourcing_score => 0 + sprintf( '%.2f', $score ),
                     rank => ( scalar @{ $req->{have} } ) / $total + 0.1 * $score };
    }
    # Stock coverage first; sourcing score (prefs/ethics/contamination) nudges ties and near-ties.
    # With no sourcing data and default prefs every score is 0, so order is unchanged.
    return [ sort { $b->{rank} <=> $a->{rank} || $a->{name} cmp $b->{name} } @out ];
}

sub _plan_rs {
    my ( $self, $c ) = @_;
    return $c->model('DBEncy')->resultset('HealthKitchen::MealPlan')->search(
        { user_id => $c->session->{user_id}, sitename => $self->sitename($c) } );
}

sub list_meal_plans {
    my ( $self, $c ) = @_;
    return [] unless $self->meal_plan_ready($c);
    my @out;
    try {
        my $rs = $self->_plan_rs($c)->search( { status => { '!=' => 'archived' } },
            { order_by => { -desc => 'id' } } );
        while ( my $p = $rs->next ) {
            push @out, { id => $p->id, name => $p->name, status => $p->status,
                         start_date => ( $p->start_date ? $p->start_date . '' : '' ),
                         end_date   => ( $p->end_date ? $p->end_date . '' : '' ) };
        }
    }
    catch {
        $self->logging->log_with_details( $c, 'error', __FILE__, __LINE__, 'list_meal_plans', "failed: $_" );
    };
    return \@out;
}

sub _clean_date {
    my ( $self, $d ) = @_;
    return ( defined $d && $d =~ /^(\d{4}-\d{2}-\d{2})$/ ) ? $1 : undef;
}

sub create_meal_plan {
    my ( $self, $c, $args ) = @_;
    return { ok => 0, error => 'Meal plan tables are not created yet. Run Schema Compare.' }
        unless $self->meal_plan_ready($c);
    my $name = $args->{name} // '';
    $name =~ s/^\s+|\s+$//g;
    return { ok => 0, error => 'Plan name is required.' } unless length $name;
    my $row;
    try {
        $row = $c->model('DBEncy')->resultset('HealthKitchen::MealPlan')->create( {
            user_id    => $c->session->{user_id},
            sitename   => $self->sitename($c),
            name       => substr( $name, 0, 255 ),
            start_date => $self->_clean_date( $args->{start_date} ),
            end_date   => $self->_clean_date( $args->{end_date} ),
            status     => 'draft',
        } );
    }
    catch {
        $self->logging->log_with_details( $c, 'error', __FILE__, __LINE__, 'create_meal_plan', "failed: $_" );
    };
    return $row ? { ok => 1, id => $row->id } : { ok => 0, error => 'Could not create plan.' };
}

sub _own_plan {
    my ( $self, $c, $plan_id ) = @_;
    return undef unless $plan_id && $plan_id =~ /^\d+$/;
    return eval { $self->_plan_rs($c)->search( { id => $plan_id } )->first };
}

sub add_meal_entry {
    my ( $self, $c, $plan_id, $args ) = @_;
    my $plan = $self->_own_plan( $c, $plan_id ) or return { ok => 0, error => 'Plan not found.' };
    my $rid = ( $args->{recipe_id} && $args->{recipe_id} =~ /^\d+$/ ) ? $args->{recipe_id} : undef;
    my $custom = $args->{custom_name} // '';
    $custom =~ s/^\s+|\s+$//g;
    return { ok => 0, error => 'Pick a recipe or type a meal name.' } unless $rid || length $custom;
    my $slot = lc( $args->{meal_slot} // 'dinner' );
    $slot = 'dinner' unless $slot =~ /^(breakfast|lunch|dinner|snack)$/;
    my $serv = ( $args->{servings} && $args->{servings} =~ /^\d+(\.\d+)?$/ && $args->{servings} > 0 ) ? $args->{servings} : 1;
    my $ok;
    try {
        $plan->create_related( entries => {
            plan_date   => $self->_clean_date( $args->{plan_date} ),
            meal_slot   => $slot,
            recipe_id   => $rid,
            custom_name => length $custom ? substr( $custom, 0, 255 ) : undef,
            servings    => $serv,
        } );
        $ok = 1;
    }
    catch {
        $self->logging->log_with_details( $c, 'error', __FILE__, __LINE__, 'add_meal_entry', "failed: $_" );
    };
    return $ok ? { ok => 1 } : { ok => 0, error => 'Could not add meal.' };
}

sub delete_meal_entry {
    my ( $self, $c, $plan_id, $entry_id ) = @_;
    my $plan = $self->_own_plan( $c, $plan_id ) or return { ok => 0, error => 'Plan not found.' };
    return { ok => 0, error => 'Invalid entry.' } unless $entry_id && $entry_id =~ /^\d+$/;
    my $n = eval { $plan->entries->search( { id => $entry_id } )->delete } || 0;
    return $n ? { ok => 1 } : { ok => 0, error => 'Entry not found.' };
}

# Plan + entries + inventory-first requirements (have vs buy).
sub get_meal_plan {
    my ( $self, $c, $plan_id ) = @_;
    my $plan = $self->_own_plan( $c, $plan_id ) or return undef;
    my @entries;
    my $recipe_rs = eval { $c->model('DBEncy')->resultset('Ency::Recipe') };
    for my $e ( $plan->entries->search( {}, { order_by => [ 'plan_date', 'meal_slot', 'id' ] } )->all ) {
        my $r;
        if ( $e->recipe_id && $recipe_rs ) {
            my $row = $recipe_rs->search( { "me.id" => $e->recipe_id }, { prefetch => 'lines' } )->first;
            $r = $self->_recipe_hash($row) if $row;
        }
        push @entries, {
            id => $e->id, plan_date => ( $e->plan_date ? $e->plan_date . '' : '' ),
            meal_slot => $e->meal_slot, servings => 0 + $e->servings,
            name => ( $r ? $r->{name} : $e->custom_name ), recipe => $r,
        };
    }
    return {
        id => $plan->id, name => $plan->name, status => $plan->status,
        start_date => ( $plan->start_date ? $plan->start_date . '' : '' ),
        end_date   => ( $plan->end_date ? $plan->end_date . '' : '' ),
        entries    => \@entries,
        requirements => $self->plan_requirements( \@entries, $self->pantry_with_products($c) ),
        allergen_warnings => [ map { { name => $_->{name}, hits => $_->{allergen_hits} } }
            @{ ( $self->filter_recipes_by_allergens( [ map { $_->{recipe} } grep { $_->{recipe} } @entries ],
                    $self->user_matching_inputs($c)->{allergens} ) )[1] } ],
    };
}

sub pantry_with_products {
    my ( $self, $c ) = @_;
    my $rows = $self->list_pantry($c);
    $self->attach_links_and_products( $c, $rows );
    return $rows;
}

sub suggest_recipes_from_stock {
    my ( $self, $c ) = @_;
    my ($ok) = $self->filter_recipes_by_allergens( $self->list_recipes($c), $self->user_matching_inputs($c)->{allergens} );
    return $self->rank_recipes_by_stock( $ok, $self->pantry_with_products($c) );
}

# Recipes allowed for this user's meal plans (allergen-filtered) + the excluded ones.
sub meal_plan_recipes {
    my ( $self, $c ) = @_;
    my ( $ok, $bad ) = $self->filter_recipes_by_allergens( $self->list_recipes($c), $self->user_matching_inputs($c)->{allergens} );
    return { allowed => $ok, excluded => $bad };
}


# ── Nutrition tracking (manual entry; import-ready via source/source_ref) ────

our @NUTRIENTS = qw(calories protein_g carbs_g fat_g fiber_g sugar_g sodium_mg);

sub nutrition_ready {
    my ( $self, $c ) = @_;
    return $self->table_ready( $c, 'HealthKitchen::FoodNutrient' )
        && $self->table_ready( $c, 'HealthKitchen::IntakeLog' );
}

sub _num {
    my ( $self, $v ) = @_;
    return undef unless defined $v && $v =~ /^\s*(\d+(?:\.\d+)?)\s*$/;
    return 0 + $1;
}

# Pure: sum snapshotted intake rows into daily totals.
sub daily_totals {
    my ( $self, $rows ) = @_;
    my %t = map { $_ => 0 } @NUTRIENTS;
    for my $r ( @{ $rows || [] } ) {
        $t{$_} += ( $r->{$_} || 0 ) for @NUTRIENTS;
    }
    $t{$_} = 0 + sprintf( '%.2f', $t{$_} ) for @NUTRIENTS;
    return \%t;
}

sub list_foods {
    my ( $self, $c ) = @_;
    return [] unless $self->nutrition_ready($c);
    my $prod = $self->_products_by_inventory($c);
    my @out;
    try {
        my $rs = $c->model('DBEncy')->resultset('HealthKitchen::FoodNutrient')->search(
            { -or => [ { sitename => $self->sitename($c) }, { sitename => undef } ] },
            { order_by => 'name', rows => 500 } );
        while ( my $f = $rs->next ) {
            push @out, { id => $f->id, name => $f->name, brand => $f->brand, source => $f->source,
                         serving_size => 0 + $f->serving_size, serving_unit => $f->serving_unit,
                         map { $_ => $f->$_ } @NUTRIENTS };
            if ( $f->inventory_item_id && ( my $p = $prod->{ $f->inventory_item_id } ) ) {
                $out[-1]{sourcing} = { badges => $p->{badges}, summary => $p->{summary}, score => $p->{score} };
                $out[-1]{adjusted} = $self->adjust_nutrients( $out[-1], $p->{factors} );
            }
        }
    }
    catch {
        $self->logging->log_with_details( $c, 'error', __FILE__, __LINE__, 'list_foods', "failed: $_" );
    };
    return \@out;
}

sub add_food {
    my ( $self, $c, $a ) = @_;
    return { ok => 0, error => 'Nutrition tables are not created yet. Run Schema Compare.' }
        unless $self->nutrition_ready($c);
    my $name = $a->{name} // '';
    $name =~ s/^\s+|\s+$//g;
    return { ok => 0, error => 'Food name is required.' } unless length $name;
    my $unit = $a->{serving_unit} // 'g';
    $unit =~ s/^\s+|\s+$//g;
    my $ok;
    try {
        $c->model('DBEncy')->resultset('HealthKitchen::FoodNutrient')->create( {
            sitename     => $self->sitename($c),
            name         => substr( $name, 0, 255 ),
            source       => 'manual',
            serving_size => $self->_num( $a->{serving_size} ) || 100,
            serving_unit => substr( length $unit ? $unit : 'g', 0, 32 ),
            created_by   => $c->session->{user_id},
            map { $_ => $self->_num( $a->{$_} ) } @NUTRIENTS,
        } );
        $ok = 1;
    }
    catch {
        $self->logging->log_with_details( $c, 'error', __FILE__, __LINE__, 'add_food', "failed: $_" );
    };
    return $ok ? { ok => 1 } : { ok => 0, error => 'Could not save food.' };
}

sub log_intake {
    my ( $self, $c, $a ) = @_;
    return { ok => 0, error => 'Nutrition tables are not created yet. Run Schema Compare.' }
        unless $self->nutrition_ready($c);
    my $date = $self->_clean_date( $a->{log_date} ) or return { ok => 0, error => 'Valid date required.' };
    my $serv = $self->_num( $a->{servings} ) || 1;
    my $fid  = ( $a->{food_nutrient_id} && $a->{food_nutrient_id} =~ /^\d+$/ ) ? $a->{food_nutrient_id} : undef;
    my $food = $fid ? eval {
        $c->model('DBEncy')->resultset('HealthKitchen::FoodNutrient')->search( {
            id => $fid, -or => [ { sitename => $self->sitename($c) }, { sitename => undef } ] } )->first
    } : undef;
    return { ok => 0, error => 'Pick a food from your list.' } unless $food;
    my $slot = lc( $a->{meal_slot} // '' );
    $slot = undef unless $slot =~ /^(breakfast|lunch|dinner|snack)$/;
    my $ok;
    try {
        $c->model('DBEncy')->resultset('HealthKitchen::IntakeLog')->create( {
            user_id => $c->session->{user_id}, sitename => $self->sitename($c),
            log_date => $date, meal_slot => $slot, food_nutrient_id => $food->id,
            food_name => $food->name, servings => $serv,
            map { my $v = $food->$_; $_ => ( defined $v ? sprintf( '%.2f', $v * $serv ) : undef ) } @NUTRIENTS,
        } );
        $ok = 1;
    }
    catch {
        $self->logging->log_with_details( $c, 'error', __FILE__, __LINE__, 'log_intake', "failed: $_" );
    };
    return $ok ? { ok => 1 } : { ok => 0, error => 'Could not log food.' };
}

sub delete_intake {
    my ( $self, $c, $id ) = @_;
    return { ok => 0, error => 'Invalid entry.' } unless $id && $id =~ /^\d+$/;
    my $n = eval {
        $c->model('DBEncy')->resultset('HealthKitchen::IntakeLog')->search( {
            id => $id, user_id => $c->session->{user_id}, sitename => $self->sitename($c) } )->delete
    } || 0;
    return $n ? { ok => 1 } : { ok => 0, error => 'Entry not found.' };
}

sub intake_for_day {
    my ( $self, $c, $date ) = @_;
    return [] unless $self->nutrition_ready($c) && $self->_clean_date($date);
    my @out;
    try {
        my $rs = $c->model('DBEncy')->resultset('HealthKitchen::IntakeLog')->search(
            { user_id => $c->session->{user_id}, sitename => $self->sitename($c), log_date => $date },
            { order_by => [ 'meal_slot', 'id' ] } );
        while ( my $r = $rs->next ) {
            push @out, { id => $r->id, meal_slot => $r->meal_slot, food_name => $r->food_name,
                         servings => 0 + $r->servings, map { $_ => $r->$_ } @NUTRIENTS };
        }
    }
    catch {
        $self->logging->log_with_details( $c, 'error', __FILE__, __LINE__, 'intake_for_day', "failed: $_" );
    };
    return \@out;
}


# ── AI recipe suggestions from in-stock inventory (inventory-first) ─────────

our $AI_RECIPE_NOTE = 'AI-generated suggestion from your in-stock food. Review before cooking: '
    . 'check quantities, allergies and food safety. Informational only, not medical advice.';

# In-stock foods that map to inventory items (only these may appear in AI recipes).
sub ai_stock_foods {
    my ( $self, $rows ) = @_;
    my ( @out, %seen );
    for my $r ( @{ $rows || [] } ) {
        next unless $r->{inventory_item_id} && ( $r->{qty} || 0 ) > 0;
        next if $seen{ $r->{inventory_item_id} }++;
        my $pr = $r->{product} || {};
        push @out, { id => 0 + $r->{inventory_item_id}, name => $r->{name},
                     qty => 0 + $r->{qty}, unit => $r->{unit} || 'each',
                     ( $pr->{badges} && @{ $pr->{badges} } ? ( sourcing => join( ', ', @{ $pr->{badges} } ) ) : () ),
                     ( defined $pr->{score} ? ( score => $pr->{score} ) : () ) };
    }
    return \@out;
}

# $prefs carries ONLY non-identifying preferences: diet_flags and ingredients to avoid.
# Never diagnoses, conditions, medications or notes.
sub ai_recipe_prompt {
    my ( $self, $foods, $count, $prefs ) = @_;
    $count ||= 3;
    $prefs ||= {};
    my $pref = '';
    if ( my $df = $prefs->{diet_flags} ) {
        $df =~ s/[^\w ,\-]//g;
        $pref .= 'Dietary style: ' . substr( $df, 0, 200 ) . ".\n" if length $df;
    }
    my @avoid = grep { length } @{ $prefs->{avoid} || [] };
    $pref .= 'Exclude these ingredients entirely: ' . join( ', ', @avoid ) . ".\n" if @avoid;
    my $use_src = grep { $prefs->{$_} } qw(prefer_organic avoid_feedlot ethics_weight);
    if ($use_src) {
        my @s;
        push @s, 'certified organic items' if $prefs->{prefer_organic};
        push @s, 'items with a higher sourcing score (better ethics, lower contamination risk)'
            if $prefs->{ethics_weight};
        $pref .= 'When choosing between in-stock items, prefer ' . join( ' and ', @s ) . ".\n" if @s;
        $pref .= "Avoid items marked Feedlot unless nothing else fits.\n" if $prefs->{avoid_feedlot};
    }
    my $list = join "\n", map {
        my $f = $_;
        ( my $src = $f->{sourcing} // '' ) =~ s/[^\w ,:()\-]//g;
        "- id=$f->{id}; name=$f->{name}; on_hand=$f->{qty} $f->{unit}"
            . ( length $src ? "; sourcing=$src" : '' )
            . ( $use_src && defined $f->{score} ? "; sourcing_score=$f->{score}" : '' )
    } @$foods;
    return "Create $count simple, wholesome home recipes using ONLY the in-stock foods below.\n"
         . "Every ingredient must be one of these items, referenced by its id. Do not invent ingredients "
         . "(water is allowed and needs no id). Do not exceed on_hand quantities. Do not make health or medical claims.\n\n"
         . $pref
         . "In stock:\n$list\n\n"
         . "Reply with JSON only, no prose: "
         . '[{"name":"...","servings":2,"cook_time_min":20,"instructions":"step 1... step 2...",'
         . '"ingredients":[{"inventory_item_id":123,"quantity":200,"unit":"g"}]}]';
}

# Pure: parse model text into recipes whose ingredients all map to stock.
sub parse_ai_recipes {
    my ( $self, $text, $foods ) = @_;
    return [] unless defined $text && length $text;
    require JSON;
    my ($json) = $text =~ /(\[.*\])/s;
    return [] unless $json;
    my $data = eval { JSON->new->relaxed->decode($json) };
    return [] unless ref $data eq 'ARRAY';
    my %by_id   = map { $_->{id} => $_ } @$foods;
    my %by_name = map { lc( $_->{name} ) => $_ } @$foods;
    my @out;
    for my $r (@$data) {
        next unless ref $r eq 'HASH' && defined $r->{name} && length $r->{name};
        my ( @lines, @dropped );
        for my $i ( @{ $r->{ingredients} || [] } ) {
            next unless ref $i eq 'HASH';
            my $iid  = $i->{inventory_item_id};
            my $food = ( defined $iid && $iid =~ /^\d+$/ ) ? $by_id{$iid} : undef;
            $food ||= $by_name{ lc( $i->{name} // '' ) } if defined $i->{name};
            if ( !$food ) {
                push @dropped, $i->{name} // $iid // '?' unless lc( $i->{name} // '' ) eq 'water';
                next;
            }
            my $q = ( defined $i->{quantity} && $i->{quantity} =~ /^\d+(\.\d+)?$/ ) ? 0 + $i->{quantity} : undef;
            push @lines, { inventory_item_id => $food->{id}, name => $food->{name},
                           quantity => $q, unit => $i->{unit} || $food->{unit} };
        }
        next if @dropped || !@lines;    # inventory-first: reject recipes needing unstocked items
        my $serv = ( defined $r->{servings} && $r->{servings} =~ /^\d+$/ && $r->{servings} > 0 ) ? 0 + $r->{servings} : 2;
        push @out, {
            name          => substr( $r->{name}, 0, 500 ),
            servings      => $serv,
            cook_time_min => ( defined $r->{cook_time_min} && $r->{cook_time_min} =~ /^\d+$/ ) ? 0 + $r->{cook_time_min} : undef,
            instructions  => ref $r->{instructions} eq 'ARRAY' ? join( "\n", @{ $r->{instructions} } ) : ( $r->{instructions} // '' ),
            lines         => \@lines,
        };
    }
    return \@out;
}

# Calls the app's AI layer ($c->model('AI')->chat_message: provider/model selection,
# usage + plan-quota logging). $opts->{ai_call} overrides the call (tests).
sub generate_ai_recipes {
    my ( $self, $c, $opts ) = @_;
    $opts ||= {};
    return { ok => 0, error => 'Recipe tables are not created yet. Run Schema Compare.' }
        unless $self->recipe_ready($c);
    my $inputs = $opts->{matching_inputs} || eval { $self->user_matching_inputs($c) } || {};
    my $profile = $opts->{profile} || eval { $self->get_profile($c) } || {};
    my @avoid = @{ $inputs->{allergens} || [] };
    my $foods = [ grep { my $n = lc $_->{name}; !grep { index( $n, $_ ) >= 0 } @avoid }
                  @{ $self->ai_stock_foods( $self->pantry_with_products($c) ) } ];
    return { ok => 0, error => 'No in-stock inventory foods found to build recipes from.' }
        unless @$foods >= 2;
    splice( @$foods, 60 ) if @$foods > 60;
    my $prompt = $self->ai_recipe_prompt( $foods, $opts->{count} || 3,
        { diet_flags => $profile->{diet_flags}, avoid => \@avoid,
          prefer_organic => $profile->{prefer_organic}, avoid_feedlot => $profile->{avoid_feedlot},
          ethics_weight => $profile->{ethics_weight} } );
    my $system = 'You are a careful home-cooking assistant for a wellness kitchen. '
               . 'Use only provided stock items. Output strict JSON.';
    my $res = $opts->{ai_call}
        ? $opts->{ai_call}->( $prompt, $system )
        : eval { $c->model('AI')->chat_message( $c, prompt => $prompt, system => $system,
                                                 page_path => '/healthkitchen/recipes' ) };
    unless ( $res && $res->{success} ) {
        my $err = ( $res && $res->{error} ) || $@ || 'AI service unavailable';
        $self->logging->log_with_details( $c, 'warning', __FILE__, __LINE__, 'generate_ai_recipes', "AI failed: $err" );
        return { ok => 0, error => "AI recipe suggestion failed: $err" };
    }
    my $recipes = $self->parse_ai_recipes( $res->{response}, $foods );
    return { ok => 0, error => 'The AI did not return any recipes that use only your stock. Try again.' }
        unless @$recipes;
    my $schema = $c->model('DBEncy');
    my @saved;
    try {
        $schema->txn_do( sub {
            my $n = 0;
            for my $r (@$recipes) {
                my $row = $schema->resultset('Ency::Recipe')->create( {
                    recipe_code        => 'HK-AI-' . strftime( '%y%m%d%H%M%S', localtime ) . '-' . ++$n,
                    name               => $r->{name},
                    recipe_kind        => 'food_recipe',
                    instructions       => $r->{instructions},
                    servings           => $r->{servings},
                    yield_amount       => $r->{servings},
                    yield_unit         => 'servings',
                    cook_time_min      => $r->{cook_time_min},
                    notes              => $AI_RECIPE_NOTE,
                    source             => 'ai_generated',
                    sitename           => $self->sitename($c),
                    status             => 'draft',
                    username_of_poster => $c->session->{username},
                } );
                my $sort = 0;
                for my $ln ( @{ $r->{lines} } ) {
                    $schema->resultset('Ency::RecipeLine')->create( {
                        recipe_id => $row->id, sort_order => ++$sort, ingredient_source => 'inventory',
                        inventory_item_id => $ln->{inventory_item_id}, name_raw => $ln->{name},
                        quantity => $ln->{quantity}, unit => $ln->{unit},
                    } );
                }
                push @saved, $row->id;
            }
        } );
    }
    catch {
        $self->logging->log_with_details( $c, 'error', __FILE__, __LINE__, 'generate_ai_recipes', "save failed: $_" );
        @saved = ();
    };
    return @saved ? { ok => 1, ids => \@saved, model => $res->{model} }
                  : { ok => 0, error => 'Could not save AI recipes.' };
}


# ── Encryption helpers (Comserv::Util::Encryption, namespace 'healthkitchen') ──
# crypto is injectable for tests; decrypt falls back to plaintext for legacy rows.

has 'crypto' => ( is => 'rw', lazy => 1, default => sub { require Comserv::Util::Encryption; 'Comserv::Util::Encryption' } );

sub _enc {
    my ( $self, $v ) = @_;
    return undef unless defined $v && length $v;
    return $v if $v =~ /^ENC:/;
    my $out = eval { $self->crypto->encrypt( $v, 'healthkitchen' ) };
    die "Health Kitchen encryption unavailable: " . ( $@ || 'no output' ) . "\n" unless $out;    # never store plaintext silently
    return $out;
}

sub _dec {
    my ( $self, $v ) = @_;
    return '' unless defined $v && length $v;
    return $v unless $v =~ /^ENC:/;
    my $out = eval { $self->crypto->decrypt( $v, 'healthkitchen' ) };
    return defined $out ? $out : '';
}

# ── Health & disease history (opt-in) ──────────────────────────────────────

our @HISTORY_TYPES  = qw(condition symptom medication allergy procedure);
our @HISTORY_STATUS = qw(active resolved managed);

sub history_ready {
    my ( $self, $c ) = @_;
    return $self->table_ready( $c, 'HealthKitchen::HealthConsent' )
        && $self->table_ready( $c, 'HealthKitchen::HealthHistory' )
        && $self->table_ready( $c, 'HealthKitchen::HealthAudit' );
}

sub _now { strftime( '%Y-%m-%d %H:%M:%S', localtime ) }

sub active_consent {
    my ( $self, $c, $user_id ) = @_;
    $user_id //= $c->session->{user_id};
    return undef unless $user_id && $self->history_ready($c);
    return eval {
        $c->model('DBEncy')->resultset('HealthKitchen::HealthConsent')->search(
            { user_id => $user_id, sitename => $self->sitename($c), revoked_at => undef },
            { order_by => { -desc => 'id' }, rows => 1 } )->first;
    };
}

sub _audit {
    my ( $self, $c, $subject, $action, $count ) = @_;
    eval {
        $c->model('DBEncy')->resultset('HealthKitchen::HealthAudit')->create( {
            actor_user_id => $c->session->{user_id}, subject_user_id => $subject,
            sitename => $self->sitename($c), action => $action, entry_count => $count } );
    };
}

sub grant_consent {
    my ( $self, $c ) = @_;
    return { ok => 0, error => 'Health history tables are not created yet. Run Schema Compare.' }
        unless $self->history_ready($c);
    return { ok => 1 } if $self->active_consent($c);
    my $ok = eval {
        my $req = $c->req;
        $c->model('DBEncy')->resultset('HealthKitchen::HealthConsent')->create( {
            user_id => $c->session->{user_id}, sitename => $self->sitename($c),
            consent_version => '1', granted_at => $self->_now,
            ip_address => $self->_enc( $req ? $req->address : undef ),
            user_agent => $self->_enc( $req ? substr( $req->user_agent // '', 0, 500 ) : undef ),
        } );
        $self->_audit( $c, $c->session->{user_id}, 'consent', undef );
        1;
    };
    $self->logging->log_with_details( $c, 'error', __FILE__, __LINE__, 'grant_consent', "failed: $@" ) unless $ok;
    return $ok ? { ok => 1 } : { ok => 0, error => 'Could not record consent.' };
}

sub revoke_consent {
    my ( $self, $c ) = @_;
    my $con = $self->active_consent($c) or return { ok => 1 };
    my $ok = eval { $con->update( { revoked_at => $self->_now } ); $self->_audit( $c, $c->session->{user_id}, 'revoke', undef ); 1 };
    return $ok ? { ok => 1 } : { ok => 0, error => 'Could not revoke consent.' };
}

sub _history_rs {
    my ( $self, $c, $user_id ) = @_;
    return $c->model('DBEncy')->resultset('HealthKitchen::HealthHistory')->search(
        { user_id => $user_id // $c->session->{user_id}, sitename => $self->sitename($c) } );
}

sub _history_hash {
    my ( $self, $r ) = @_;
    return {
        id => $r->id, entry_type => $r->entry_type, label => $self->_dec( $r->label ),
        notes => $self->_dec( $r->notes ), status => $r->status,
        ency_disease_id => $r->ency_disease_id, ency_symptom_id => $r->ency_symptom_id,
        ency_drug_id => $r->ency_drug_id,
        onset_date => ( $r->onset_date ? $r->onset_date . '' : '' ),
        resolved_date => ( $r->resolved_date ? $r->resolved_date . '' : '' ),
        severity => $r->severity, use_for_matching => $r->use_for_matching ? 1 : 0,
        visibility => $r->visibility,
    };
}

# Own entries; requires active consent (no consent = no reads, no use).
sub list_history {
    my ( $self, $c ) = @_;
    return [] unless $self->active_consent($c);
    my @out;
    try {
        push @out, $self->_history_hash($_)
            for $self->_history_rs($c)->search( {}, { order_by => [ { -desc => 'onset_date' }, { -desc => 'id' } ] } )->all;
    }
    catch {
        $self->logging->log_with_details( $c, 'error', __FILE__, __LINE__, 'list_history', "failed: $_" );
    };
    return \@out;
}

sub _clean_history_args {
    my ( $self, $a ) = @_;
    my %h;
    my $type = lc( $a->{entry_type} // 'condition' );
    $h{entry_type} = ( grep { $_ eq $type } @HISTORY_TYPES ) ? $type : 'condition';
    my $st = lc( $a->{status} // 'active' );
    $h{status} = ( grep { $_ eq $st } @HISTORY_STATUS ) ? $st : 'active';
    for my $k (qw(ency_disease_id ency_symptom_id ency_drug_id)) {
        $h{$k} = ( defined $a->{$k} && $a->{$k} =~ /^\d+$/ ) ? 0 + $a->{$k} : undef;
    }
    $h{onset_date}    = $self->_clean_date( $a->{onset_date} );
    $h{resolved_date} = $self->_clean_date( $a->{resolved_date} );
    my $sev = lc( $a->{severity} // '' );
    $h{severity} = $sev =~ /^(mild|moderate|severe)$/ ? $sev : undef;
    $h{use_for_matching} = ( defined $a->{use_for_matching} && !$a->{use_for_matching} ) ? 0 : 1;
    $h{visibility} = ( ( $a->{visibility} // '' ) eq 'site_admin' ) ? 'site_admin' : 'private';
    my $label = $a->{label} // '';
    $label =~ s/^\s+|\s+$//g;
    $h{label} = substr( $label, 0, 255 );
    $h{notes} = defined $a->{notes} ? substr( $a->{notes}, 0, 5000 ) : undef;
    return \%h;
}

sub save_history {
    my ( $self, $c, $a ) = @_;
    return { ok => 0, error => 'Please give consent before adding health history.' } unless $self->active_consent($c);
    my $h = $self->_clean_history_args($a);
    return { ok => 0, error => 'Enter a name or pick an ENCY entry.' }
        unless length $h->{label} || $h->{ency_disease_id} || $h->{ency_symptom_id} || $h->{ency_drug_id};
    $h->{label} = $self->_enc( $h->{label} );
    $h->{notes} = $self->_enc( $h->{notes} );
    my $ok = eval {
        if ( $a->{id} && $a->{id} =~ /^\d+$/ ) {
            my $row = $self->_history_rs($c)->search( { id => $a->{id} } )->first or die "not found\n";
            $row->update($h);
        }
        else {
            $self->_history_rs($c)->create($h);
        }
        1;
    };
    $self->logging->log_with_details( $c, 'error', __FILE__, __LINE__, 'save_history', "failed: $@" ) unless $ok;
    return $ok ? { ok => 1 } : { ok => 0, error => 'Could not save entry.' };
}

sub delete_history {
    my ( $self, $c, $id ) = @_;
    return { ok => 0, error => 'Invalid entry.' } unless $id && $id =~ /^\d+$/;
    my $n = eval { $self->_history_rs($c)->search( { id => $id } )->delete } || 0;
    return $n > 0 ? { ok => 1 } : { ok => 0, error => 'Entry not found.' };
}

# Hard delete of all history + consent rows for this user/site (audit keeps only counts).
sub delete_all_history {
    my ( $self, $c, $confirm ) = @_;
    return { ok => 0, error => 'Type DELETE to confirm.' } unless defined $confirm && $confirm eq 'DELETE';
    return { ok => 0, error => 'Health history tables are not created yet.' } unless $self->history_ready($c);
    my $n = 0;
    my $ok = eval {
        $n = $self->_history_rs($c)->count;
        $self->_history_rs($c)->delete;
        $c->model('DBEncy')->resultset('HealthKitchen::HealthConsent')->search(
            { user_id => $c->session->{user_id}, sitename => $self->sitename($c) } )->delete;
        $self->_audit( $c, $c->session->{user_id}, 'delete_all', $n );
        1;
    };
    return $ok ? { ok => 1, deleted => $n } : { ok => 0, error => 'Could not delete health history.' };
}

our @EXPORT_COLS = qw(id entry_type label status onset_date resolved_date severity ency_disease_id ency_symptom_id ency_drug_id use_for_matching visibility notes);

sub export_history {
    my ( $self, $c, $format ) = @_;
    my $rows = $self->list_history($c);
    $self->_audit( $c, $c->session->{user_id}, 'export', scalar @$rows ) if $self->history_ready($c);
    return $self->history_to_csv($rows) if ( $format // '' ) eq 'csv';
    require JSON;
    return JSON->new->canonical->pretty->encode( { exported_at => $self->_now, sitename => $self->sitename($c), entries => $rows } );
}

sub history_to_csv {
    my ( $self, $rows ) = @_;
    my $q = sub { my $v = $_[0] // ''; $v =~ s/"/""/g; $v = "'$v" if $v =~ /^[=+\-@]/; qq{"$v"} };
    return join( "\n", join( ',', @EXPORT_COLS ),
        map { my $r = $_; join( ',', map { $q->( $r->{$_} ) } @EXPORT_COLS ) } @$rows ) . "\n";
}

# Admin view of ONE user's entries that user shared (visibility=site_admin). Audited.
sub admin_shared_history {
    my ( $self, $c, $subject_id ) = @_;
    return [] unless $subject_id && $subject_id =~ /^\d+$/ && $self->active_consent( $c, $subject_id );
    my @rows = map { $self->_history_hash($_) }
        eval { $self->_history_rs( $c, $subject_id )->search( { visibility => 'site_admin' } )->all };
    $self->_audit( $c, $subject_id, 'admin_view', scalar @rows );
    return \@rows;
}

# Pure: turn decrypted history + profile into matching inputs.
sub history_matching_inputs {
    my ( $self, $history, $profile ) = @_;
    my ( %terms, %drugs, %diseases, %allergens );
    for my $h ( @{ $history || [] } ) {
        next unless $h->{use_for_matching};
        next if ( $h->{status} // '' ) eq 'resolved';
        my $label = lc( $h->{label} // '' );
        $label =~ s/^\s+|\s+$//g;
        if ( $h->{entry_type} eq 'allergy' ) {
            $allergens{$label} = 1 if length $label;
            next;
        }
        $terms{$label} = 1 if length $label >= 3 && $h->{entry_type} =~ /^(condition|medication|procedure)$/;
        $drugs{ $h->{ency_drug_id} }       = 1 if $h->{ency_drug_id};
        $diseases{ $h->{ency_disease_id} } = 1 if $h->{ency_disease_id} && $h->{entry_type} eq 'condition';
    }
    for my $a ( split /\s*[,;\n]\s*/, lc( ( $profile || {} )->{allergies} // '' ) ) {
        $a =~ s/^\s+|\s+$//g;
        $allergens{$a} = 1 if length $a;
    }
    return { contra_terms => [ sort keys %terms ], drug_ids => [ sort { $a <=> $b } keys %drugs ],
             disease_ids => [ sort { $a <=> $b } keys %diseases ], allergens => [ sort keys %allergens ] };
}

sub user_matching_inputs {
    my ( $self, $c ) = @_;
    return $self->history_matching_inputs( $self->list_history($c), $self->get_profile($c) );
}

# Pure: split recipes into allowed / excluded by allergen terms found in ingredient names.
sub filter_recipes_by_allergens {
    my ( $self, $recipes, $allergens ) = @_;
    my @terms = grep { length } @{ $allergens || [] };
    return ( $recipes || [], [] ) unless @terms;
    my ( @ok, @bad );
    for my $r ( @{ $recipes || [] } ) {
        my @hit;
        for my $ln ( @{ $r->{lines} || [] } ) {
            my $n = lc( $ln->{name} // '' );
            push @hit, grep { index( $n, $_ ) >= 0 } @terms;
        }
        if (@hit) { my %u = map { $_ => 1 } @hit; push @bad, { %$r, allergen_hits => [ sort keys %u ] } }
        else      { push @ok, $r }
    }
    return ( \@ok, \@bad );
}

# ---------------------------------------------------------------------------
# User-added ENCY symptoms (dedupe case-insensitive exact, tagged for review)
# ---------------------------------------------------------------------------
our $USER_ADDED_GROUP = 'hk_user_added';
our $USER_ADDED_REF   = 'User-added via HealthKitchen; pending ENCY review';

sub normalize_symptom_name {
    my ( $self, $name ) = @_;
    return '' unless defined $name;
    $name =~ s/^\s+|\s+$//g;
    $name =~ s/\s+/ /g;
    return $name;
}

# Pure: find an existing symptom whose name or common_name equals $name (case-insensitive).
sub find_symptom_dup {
    my ( $self, $name, $list ) = @_;
    my $want = lc $self->normalize_symptom_name($name);
    return undef unless length $want;
    for my $s ( @{ $list || [] } ) {
        for my $f (qw(name common_name)) {
            my $v = lc $self->normalize_symptom_name( $s->{$f} );
            return $s if length $v && $v eq $want;
        }
    }
    return undef;
}

sub pending_ready {
    my ( $self, $c ) = @_;
    return $self->table_ready( $c, 'HealthKitchen::PendingEncyAddition' );
}

# Pure: strip HTML/control chars, normalise whitespace.
sub clean_text {
    my ( $self, $v ) = @_;
    return '' unless defined $v;
    $v =~ s/<!--.*?-->//gs;
    $v =~ s/<[^>]*>//gs;
    $v =~ s/[<>]//g;
    $v =~ s/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]//g;
    $v =~ s/[ \t]+/ /g;
    $v =~ s/^\s+|\s+$//g;
    return $v;
}

# Pure: returns ( \%clean, $error ).
sub validate_symptom_submission {
    my ( $self, $a ) = @_;
    my $name = $self->normalize_symptom_name( $self->clean_text( $a->{name} ) );
    return ( undef, 'Symptom name is required.' ) unless length $name;
    return ( undef, 'Symptom name must be 2-120 characters.' ) if length($name) < 2 || length($name) > 120;
    return ( undef, q{Symptom name may only contain letters, numbers, spaces and - ' ( ) , . /} )
        unless $name =~ m{^[\p{L}\p{N}][\p{L}\p{N} \-'(),./]*$};
    my $desc = $self->clean_text( $a->{description} );
    return ( undef, 'Description must be 2000 characters or fewer.' ) if length($desc) > 2000;
    my $sev = $self->clean_text( $a->{severity} );
    return ( undef, 'Severity must be 40 characters or fewer.' ) if length($sev) > 40;
    return ( { name => $name, description => ( length $desc ? $desc : undef ),
               severity => ( length $sev ? $sev : undef ) }, undef );
}

sub _find_ency_symptom_id {
    my ( $self, $c, $name ) = @_;
    my $hit = $c->model('DBEncy')->resultset('Ency::Symptom')->search(
        { -or => [ \[ 'LOWER(TRIM(name)) = ?', lc $name ], \[ 'LOWER(TRIM(common_name)) = ?', lc $name ] ] },
        { rows => 1, columns => ['record_id'] }
    )->single;
    return $hit ? $hit->record_id : undef;
}

# Existing ENCY match -> activate now. Otherwise stage for review + notify staff via todo.
sub add_user_symptom {
    my ( $self, $c, $args ) = @_;
    return { ok => 0, error => 'Please log in.' } unless $c->session->{user_id};
    my ( $v, $err ) = $self->validate_symptom_submission($args);
    return { ok => 0, error => $err } if $err;
    my $sid = eval { $self->_find_ency_symptom_id( $c, $v->{name} ) };
    if ($sid) {
        my $r = $self->set_active_symptom( $c, { symptom_id => $sid, severity => $v->{severity} } );
        $r->{existing} = 1;
        return $r;
    }
    return { ok => 0, error => 'Review queue table is not created yet. Run schema-compare.' }
        unless $self->pending_ready($c);
    my ( $row, $dup );
    try {
        my $rs = $c->model('DBEncy')->resultset('HealthKitchen::PendingEncyAddition');
        for my $p ( $rs->search( { user_id => $c->session->{user_id}, sitename => $self->sitename($c),
                                    entity_type => 'symptom', status => 'pending' } )->all ) {
            my $d = eval { decode_json( $p->payload ) } || {};
            if ( lc( $d->{name} // '' ) eq lc $v->{name} ) { $dup = $p; last }
        }
        $row = $dup || $rs->create( {
            user_id     => $c->session->{user_id},
            username    => $c->session->{username},
            sitename    => $self->sitename($c),
            entity_type => 'symptom',
            payload     => encode_json($v),
            status      => 'pending',
        } );
    }
    catch {
        $self->logging->log_with_details( $c, 'error', __FILE__, __LINE__, 'add_user_symptom',
            "stage failed: $_" );
    };
    return { ok => 0, error => 'Could not submit symptom for review.' } unless $row;
    $self->_notify_staff_pending( $c, $row, $v ) unless $dup || $row->todo_id;
    return { ok => 1, pending => 1, pending_id => $row->id, duplicate => $dup ? 1 : 0 };
}

sub _notify_staff_pending {
    my ( $self, $c, $row, $v ) = @_;
    try {
        my $today = strftime( '%Y-%m-%d', localtime );
        my $due   = strftime( '%Y-%m-%d', localtime( time + 3 * 86400 ) );
        my $todo  = $c->model('DBEncy')->resultset('Todo')->create( {
            sitename            => $self->sitename($c),
            start_date          => $today,
            parent_todo         => '',
            due_date            => $due,
            subject             => 'Review ENCY symptom submission #' . $row->id,
            description         => 'A user submitted a new ENCY symptom for review. '
                . 'Open /healthkitchen/review to approve or reject. Name: ' . $v->{name},
            estimated_man_hours => 0,
            comments            => '',
            reporter            => 'healthkitchen',
            company_code        => 'default',
            owner               => 'admin',
            project_code        => '',
            developer           => 'admin',
            username_of_poster  => 'healthkitchen',
            status              => 'NEW',
            priority            => 3,
            share               => 0,
            last_mod_by         => 'healthkitchen',
            last_mod_date       => $today,
            user_id             => 0,
            group_of_poster     => 'admin',
            date_time_posted    => $today,
        } );
        $row->update( { todo_id => $todo->id } ) if $todo;
    }
    catch {
        $self->logging->log_with_details( $c, 'warning', __FILE__, __LINE__, '_notify_staff_pending',
            "todo create failed (submission still queued): $_" );
    };
}

# Submitter's own pending symptom submissions, shown as 'pending review'.
sub list_pending_symptoms_for_user {
    my ( $self, $c ) = @_;
    return [] unless $c->session->{user_id} && $self->pending_ready($c);
    my @out;
    try {
        for my $p ( $c->model('DBEncy')->resultset('HealthKitchen::PendingEncyAddition')->search(
                { user_id => $c->session->{user_id}, sitename => $self->sitename($c),
                  entity_type => 'symptom', status => 'pending' }, { order_by => 'id' } )->all ) {
            my $d = eval { decode_json( $p->payload ) } || {};
            push @out, { pending_id => $p->id, name => $d->{name}, severity => $d->{severity},
                         status => 'pending review' };
        }
    }
    catch {
        $self->logging->log_with_details( $c, 'error', __FILE__, __LINE__, 'list_pending_symptoms_for_user', "$_" );
    };
    return \@out;
}

sub list_pending_review {
    my ( $self, $c, $status ) = @_;
    return [] unless $self->pending_ready($c);
    $status = 'pending' unless $status && $status =~ /^(pending|approved|rejected)$/;
    my @out;
    try {
        for my $p ( $c->model('DBEncy')->resultset('HealthKitchen::PendingEncyAddition')->search(
                { status => $status, sitename => $self->sitename($c) },
                { order_by => { -desc => 'id' }, rows => 200 } )->all ) {
            my $d = eval { decode_json( $p->payload ) } || {};
            push @out, {
                id => $p->id, entity_type => $p->entity_type, status => $p->status,
                name => $d->{name}, description => $d->{description},
                submitted_by => $p->username || ( 'user#' . $p->user_id ),
                created_at => ( $p->get_column('created_at') // '' ),
                reviewer => $p->reviewer_username, review_notes => $p->review_notes,
                ency_record_id => $p->ency_record_id,
                existing_match => eval { $self->_find_ency_symptom_id( $c, $d->{name} // '' ) },
            };
        }
    }
    catch {
        $self->logging->log_with_details( $c, 'error', __FILE__, __LINE__, 'list_pending_review', "$_" );
    };
    return \@out;
}

# decision: approve|reject. Approve creates (or reuses) the ENCY symptom without
# personal data, then activates it for the submitter.
sub review_pending {
    my ( $self, $c, $args ) = @_;
    return { ok => 0, error => 'Review queue table is not created yet.' } unless $self->pending_ready($c);
    my $id = $self->_opt_id( $args->{id} ) or return { ok => 0, error => 'Bad submission id.' };
    my $decision = $args->{decision} // '';
    return { ok => 0, error => 'Choose approve or reject.' } unless $decision =~ /^(approve|reject)$/;
    my $notes = $self->clean_text( $args->{notes} );
    $notes = substr( $notes, 0, 2000 );
    my ( $res, $schema ) = ( undef, $c->model('DBEncy') );
    try {
        $schema->txn_do( sub {
            my $p = $schema->resultset('HealthKitchen::PendingEncyAddition')->search(
                { id => $id, sitename => $self->sitename($c), status => 'pending' },
                { for => 'update' } )->single or die "not pending\n";
            my %rev = (
                reviewer_user_id  => $c->session->{user_id},
                reviewer_username => $c->session->{username},
                review_notes      => ( length $notes ? $notes : undef ),
                reviewed_at       => strftime( '%Y-%m-%d %H:%M:%S', localtime ),
            );
            if ( $decision eq 'reject' ) {
                $p->update( { %rev, status => 'rejected' } );
                $res = { ok => 1, decision => 'rejected' };
                return;
            }
            my $d = decode_json( $p->payload );
            my ( $v, $err ) = $self->validate_symptom_submission($d);
            die "invalid: $err\n" if $err;
            my $sid = $self->_find_ency_symptom_id( $c, $v->{name} );
            my $created = 0;
            unless ($sid) {
                my $s = $schema->resultset('Ency::Symptom')->create( {
                    name               => $v->{name},
                    description        => $v->{description},
                    reference          => 'Submitted via HealthKitchen; approved by staff',
                    sitename           => $p->sitename,
                    username_of_poster => $c->session->{username} || 'hk-review',
                    group_of_poster    => $USER_ADDED_GROUP,
                    date_time_posted   => _now_str(),
                    share              => 0,
                } );
                $sid = $s->record_id;
                $created = 1;
            }
            $self->_activate_for( $c, $p->user_id, $p->sitename, $sid, $v->{severity} );
            $p->update( { %rev, status => 'approved', ency_record_id => $sid } );
            $res = { ok => 1, decision => 'approved', symptom_id => $sid, created => $created };
        } );
    }
    catch {
        my $e = "$_";
        $res = { ok => 0, error => $e =~ /not pending/ ? 'Submission not found or already reviewed.'
                                  : $e =~ /invalid: (.*)/ ? "Submission is invalid: $1" : 'Review failed.' };
        $self->logging->log_with_details( $c, 'error', __FILE__, __LINE__, 'review_pending', "review failed: $e" );
    };
    if ( $res && $res->{ok} ) {
        try {
            my $p = $schema->resultset('HealthKitchen::PendingEncyAddition')->find($id);
            if ( $p && $p->todo_id ) {
                my $t = $schema->resultset('Todo')->find( $p->todo_id );
                $t->update( { status => 'COMPLETED', last_mod_by => $c->session->{username} || 'healthkitchen',
                              last_mod_date => strftime( '%Y-%m-%d', localtime ) } ) if $t;
            }
        }
        catch { };
    }
    return $res;
}

sub _activate_for {
    my ( $self, $c, $user_id, $site, $sid, $severity ) = @_;
    return unless $self->symptom_ready($c);
    my $rs  = $c->model('DBEncy')->resultset('HealthKitchen::UserActiveSymptom');
    my $row = $rs->search( { user_id => $user_id, sitename => $site, symptom_id => $sid } )->single;
    if ($row) { $row->update( { status => 'active', resolved_at => undef } ) }
    else {
        $rs->create( { user_id => $user_id, sitename => $site, symptom_id => $sid,
                       severity => $severity, status => 'active' } );
    }
}

sub _now_str {
    my @t = localtime;
    return sprintf( '%04d-%02d-%02d %02d:%02d:%02d', $t[5] + 1900, $t[4] + 1, @t[ 3, 2, 1, 0 ] );
}

# ---------------------------------------------------------------------------
# Inventory/pantry item -> many ENCY entities (herb, animal, constituent)
# ---------------------------------------------------------------------------
our %LINK_ENTITY = (
    herb        => { source => 'Ency::Herb',        label => [qw(key_name botanical_name common_names)], path => '/ENCY/Herb' },
    animal      => { source => 'Ency::Animal',      label => [qw(common_name scientific_name)], path => '/ENCY/Animal' },
    constituent => { source => 'Ency::Constituent', label => [qw(name common_name)],            path => '/ENCY/Constituent' },
);
our %ITEM_KIND = ( inventory => 1, pantry => 1 );

sub link_ready {
    my ( $self, $c ) = @_;
    return $self->table_ready( $c, 'HealthKitchen::InventoryEncyLink' );
}

sub product_ready {
    my ( $self, $c ) = @_;
    return $self->table_ready( $c, 'HealthKitchen::ItemProduct' );
}

# Pure validation; returns ( \%clean, $error ).
sub validate_link_args {
    my ( $self, $a ) = @_;
    my $kind = lc( $a->{item_kind} // '' );
    my $type = lc( $a->{entity_type} // '' );
    return ( undef, 'Unknown item kind.' )   unless $ITEM_KIND{$kind};
    return ( undef, 'Unknown ENCY type.' )   unless $LINK_ENTITY{$type};
    my $iid = $self->_opt_id( $a->{item_id} );
    my $eid = $self->_opt_id( $a->{entity_id} );
    return ( undef, 'Item id is required.' )       unless $iid;
    return ( undef, 'Pick an ENCY entry to link.' ) unless $eid;
    return ( { item_kind => $kind, item_id => $iid, entity_type => $type, entity_id => $eid }, undef );
}

# Pure: digits only; accepts "8 36676 00001 9". Valid lengths 8/12/13/14. Returns '' when invalid.
sub normalize_upc {
    my ( $self, $v ) = @_;
    return '' unless defined $v;
    ( my $d = $v ) =~ s/[\s\-]//g;
    return '' unless $d =~ /^\d+$/;
    return '' unless grep { length($d) == $_ } ( 8, 12, 13, 14 );
    return $d;
}

# Pure: GS1 check digit validation (UPC-A/EAN-8/EAN-13/GTIN-14).
sub upc_check_ok {
    my ( $self, $d ) = @_;
    return 0 unless defined $d && $d =~ /^\d{8,14}$/;
    my @n   = reverse split //, $d;
    my $chk = shift @n;
    my $sum = 0;
    for my $i ( 0 .. $#n ) { $sum += $n[$i] * ( $i % 2 == 0 ? 3 : 1 ) }
    return ( ( 10 - $sum % 10 ) % 10 ) == $chk ? 1 : 0;
}

# Pure: "10 ml" / "10ml" / "1.5 L" -> ( 10, 'ml' ).
sub parse_size {
    my ( $self, $v ) = @_;
    return () unless defined $v && $v =~ /^\s*(\d+(?:\.\d+)?)\s*([A-Za-z][A-Za-z .]{0,19}?)?\s*$/;
    my ( $n, $u ) = ( 0 + $1, defined $2 ? lc $2 : undef );
    return ( $n, $u );
}

sub _item_owned {
    my ( $self, $c, $kind, $iid ) = @_;
    my $schema = $c->model('DBEncy');
    if ( $kind eq 'inventory' ) {
        return $schema->resultset('InventoryItem')->search(
            { id => $iid, sitename => $self->sitename($c) } )->count ? 1 : 0;
    }
    return 0 unless $self->pantry_ready($c);
    return $schema->resultset('HealthKitchen::UserPantryQty')->search(
        { id => $iid, sitename => $self->sitename($c), user_id => $c->session->{user_id} } )->count ? 1 : 0;
}

sub _entity_label {
    my ( $self, $row, $type ) = @_;
    for my $f ( @{ $LINK_ENTITY{$type}{label} } ) {
        my $v = eval { $row->get_column($f) };
        return $v if defined $v && length $v;
    }
    return "#" . $row->record_id;
}

sub add_ency_link {
    my ( $self, $c, $args ) = @_;
    return { ok => 0, error => 'ENCY link table is not created yet. Run schema-compare.' }
        unless $self->link_ready($c);
    my ( $a, $err ) = $self->validate_link_args($args);
    return { ok => 0, error => $err } if $err;
    my $ok = 0;
    try {
        my $schema = $c->model('DBEncy');
        die "item not yours\n" unless $self->_item_owned( $c, $a->{item_kind}, $a->{item_id} );
        die "entity missing\n"
            unless $schema->resultset( $LINK_ENTITY{ $a->{entity_type} }{source} )->find( $a->{entity_id} );
        $schema->resultset('HealthKitchen::InventoryEncyLink')->find_or_create(
            { %$a, sitename => $self->sitename($c), added_by_user_id => $c->session->{user_id} },
            { key => 'hk_link_unique' }
        );
        $ok = 1;
    }
    catch {
        $err = /item not yours/ ? 'That item is not on your site/pantry.'
             : /entity missing/ ? 'ENCY entry not found.'
             : 'Could not save ENCY link.';
        $self->logging->log_with_details( $c, 'error', __FILE__, __LINE__, 'add_ency_link',
            "add_ency_link failed: $_" );
    };
    return $ok ? { ok => 1 } : { ok => 0, error => $err };
}

sub remove_ency_link {
    my ( $self, $c, $link_id ) = @_;
    return { ok => 0, error => 'ENCY link table is not created yet.' } unless $self->link_ready($c);
    my $id = $self->_opt_id($link_id) or return { ok => 0, error => 'Bad link id.' };
    my $n = 0;
    try {
        my $row = $c->model('DBEncy')->resultset('HealthKitchen::InventoryEncyLink')->search(
            { id => $id, sitename => $self->sitename($c) } )->single;
        if ( $row && $self->_item_owned( $c, $row->item_kind, $row->item_id ) ) {
            $row->delete;
            $n = 1;
        }
    }
    catch {
        $self->logging->log_with_details( $c, 'error', __FILE__, __LINE__, 'remove_ency_link',
            "remove_ency_link failed: $_" );
    };
    return $n ? { ok => 1 } : { ok => 0, error => 'Link not found.' };
}

# Search ENCY entities by name for the link picker.
sub search_ency_entities {
    my ( $self, $c, $type, $q ) = @_;
    my $def = $LINK_ENTITY{ lc( $type // '' ) } or return [];
    $q = $self->normalize_symptom_name($q);
    return [] unless length($q) >= 2;
    ( my $like = $q ) =~ s/([%_\\])/\\$1/g;
    my @out;
    try {
        my $rs = $c->model('DBEncy')->resultset( $def->{source} )->search(
            { -or => [ map { { $_ => { -like => "%$like%" } } } @{ $def->{label} } ] },
            { rows => 25, columns => [ 'record_id', @{ $def->{label} } ], order_by => $def->{label}[0] }
        );
        while ( my $r = $rs->next ) {
            push @out, { id => $r->record_id, label => $self->_entity_label( $r, lc $type ), type => lc $type };
        }
    }
    catch {
        $self->logging->log_with_details( $c, 'warning', __FILE__, __LINE__, 'search_ency_entities',
            "search_ency_entities failed: $_" );
    };
    return \@out;
}

sub save_item_product {
    my ( $self, $c, $args ) = @_;
    return { ok => 0, error => 'Product table is not created yet. Run schema-compare.' }
        unless $self->product_ready($c);
    my $kind = lc( $args->{item_kind} // '' );
    my $iid  = $self->_opt_id( $args->{item_id} );
    return { ok => 0, error => 'Unknown item.' } unless $ITEM_KIND{$kind} && $iid;
    my $upc = '';
    if ( defined $args->{upc} && $args->{upc} =~ /\S/ ) {
        $upc = $self->normalize_upc( $args->{upc} );
        return { ok => 0, error => 'UPC/barcode must be 8, 12, 13 or 14 digits.' } unless $upc;
    }
    my ( $sv, $su ) = $self->parse_size( $args->{size} );
    return { ok => 0, error => 'Size should look like "10 ml".' }
        if defined $args->{size} && $args->{size} =~ /\S/ && !defined $sv;
    my $brand = $args->{brand};
    $brand = undef if defined $brand && $brand !~ /\S/;
    my $src_ok = $self->sourcing_cols_ready($c);
    my $src;
    if ( $src_ok && $args->{sourcing_submitted} ) {
        ( $src, my $serr ) = $self->validate_sourcing($args);
        return { ok => 0, error => $serr } if $serr;
    }
    my ( $ok, $err ) = ( 0, 'Could not save product details.' );
    try {
        die "item not yours\n" unless $self->_item_owned( $c, $kind, $iid );
        my $rs  = $c->model('DBEncy')->resultset('HealthKitchen::ItemProduct');
        my %key = ( sitename => $self->sitename($c), item_kind => $kind, item_id => $iid );
        my %data = ( brand => $brand, upc => ( length $upc ? $upc : undef ), size_value => $sv, size_unit => $su );
        %data = ( %data, %$src ) if $src;
        my $row = $rs->search( \%key, ( $src_ok ? {} : { columns => $self->_base_cols( $c, 'HealthKitchen::ItemProduct', \@SOURCING_COLS ) } ) )->single;
        if ($row) { $row->update( \%data ) }
        else      { $rs->create( { %key, %data } ) }
        $ok = 1;
    }
    catch {
        $err = 'That item is not on your site/pantry.' if /item not yours/;
        $self->logging->log_with_details( $c, 'error', __FILE__, __LINE__, 'save_item_product',
            "save_item_product failed: $_" );
    };
    return $ok ? { ok => 1, upc_check => ( length $upc ? $self->upc_check_ok($upc) : undef ) }
               : { ok => 0, error => $err };
}

# Attach ency_links => [ {id,type,entity_id,label,path} ] and product => {...} to pantry rows.
sub attach_links_and_products {
    my ( $self, $c, $rows ) = @_;
    return unless $rows && @$rows;
    my $site = $self->sitename($c);
    for my $r (@$rows) {
        $r->{item_kind} = $r->{via} && $r->{via} eq 'pantry' ? 'pantry' : 'inventory';
        $r->{item_key_id} = $r->{item_kind} eq 'pantry' ? $r->{id} : ( $r->{inventory_item_id} || $r->{id} );
        $r->{ency_links} = [];
        $r->{product} = { upc => $r->{barcode} };
    }
    my %by = map { ( "$_->{item_kind}:" . ( $_->{item_key_id} // '' ) ) => $_ } @$rows;
    my $schema = $c->model('DBEncy');
    if ( $self->link_ready($c) ) {
        try {
            my @links = $schema->resultset('HealthKitchen::InventoryEncyLink')->search(
                { sitename => $site }, { order_by => [qw(entity_type id)] } )->all;
            my %ids;
            push @{ $ids{ $_->entity_type } }, $_->entity_id for @links;
            my %label;
            for my $t ( keys %ids ) {
                my $def = $LINK_ENTITY{$t} or next;
                for my $e ( $schema->resultset( $def->{source} )->search(
                        { record_id => { -in => $ids{$t} } },
                        { columns => [ 'record_id', @{ $def->{label} } ] } )->all ) {
                    $label{"$t:" . $e->record_id} = $self->_entity_label( $e, $t );
                }
            }
            for my $l (@links) {
                my $r = $by{ $l->item_kind . ':' . $l->item_id } or next;
                push @{ $r->{ency_links} }, {
                    id        => $l->id,
                    type      => $l->entity_type,
                    entity_id => $l->entity_id,
                    label     => $label{ $l->entity_type . ':' . $l->entity_id } // ( '#' . $l->entity_id ),
                    path      => ( $LINK_ENTITY{ $l->entity_type } || {} )->{path},
                };
            }
        }
        catch {
            $self->logging->log_with_details( $c, 'error', __FILE__, __LINE__, 'attach_links_and_products',
                "links failed: $_" );
        };
    }
    if ( $self->product_ready($c) ) {
        try {
            my $src_ok  = $self->sourcing_cols_ready($c);
            my $factors = $src_ok ? $self->list_sourcing_factors($c) : [];
            my $prefs   = $src_ok ? $self->get_prefs($c) : {};
            for my $p ( $schema->resultset('HealthKitchen::ItemProduct')->search( { sitename => $site },
                    ( $src_ok ? {} : { columns => $self->_base_cols( $c, 'HealthKitchen::ItemProduct', \@SOURCING_COLS ) } ) )->all ) {
                my $r = $by{ $p->item_kind . ':' . $p->item_id } or next;
                $r->{product} = {
                    brand      => $p->brand,
                    upc        => $p->upc // $r->{barcode},
                    size_value => $p->size_value,
                    size_unit  => $p->size_unit,
                };
                if ($src_ok) {
                    $r->{product}{$_} = $p->get_column($_) for @SOURCING_COLS;
                    $self->_enrich_product( $r->{product}, $factors, $prefs );
                }
            }
        }
        catch {
            $self->logging->log_with_details( $c, 'error', __FILE__, __LINE__, 'attach_links_and_products',
                "products failed: $_" );
        };
    }
    return;
}

# ---------------------------------------------------------------------------
# Production / sourcing attributes (hk_item_product columns + hk_sourcing_factor)
# ---------------------------------------------------------------------------

sub sourcing_enums { return \%SOURCING_ENUM }

# Do these columns exist in the live DB? Cached per request in the stash.
sub _cols_ready {
    my ( $self, $c, $source, $cols ) = @_;
    my $key = "hk_cols_ready:$source";
    return $c->stash->{$key} if defined $c->stash->{$key};
    my $ok = 0;
    if ( $self->table_ready( $c, $source ) ) {
        try {
            $c->model('DBEncy')->resultset($source)->search( {}, { columns => $cols, rows => 1 } )->first;
            $ok = 1;
        }
        catch { $ok = 0 };
    }
    return $c->stash->{$key} = $ok;
}

sub sourcing_cols_ready {
    my ( $self, $c ) = @_;
    return $self->_cols_ready( $c, 'HealthKitchen::ItemProduct', [@SOURCING_COLS] );
}

sub prefs_cols_ready {
    my ( $self, $c ) = @_;
    return $self->_cols_ready( $c, 'HealthKitchen::UserHealthProfile', [@PREF_COLS] );
}

sub factor_ready {
    my ( $self, $c ) = @_;
    return $self->table_ready( $c, 'HealthKitchen::SourcingFactor' );
}

# Columns of a source minus the given (not-yet-created) ones.
sub _base_cols {
    my ( $self, $c, $source, $exclude ) = @_;
    my %x = map { $_ => 1 } @$exclude;
    return [ grep { !$x{$_} } $c->model('DBEncy')->source($source)->columns ];
}

# Pure: validate sourcing input against allowed values. Returns ( \%clean, $error ).
# Empty/absent -> undef (cleared).
sub validate_sourcing {
    my ( $self, $a ) = @_;
    my %out;
    for my $f ( keys %SOURCING_ENUM ) {
        my $v = $a->{$f};
        if ( !defined $v || $v eq '' ) { $out{$f} = undef; next }
        $v = lc $v;
        return ( undef, "Invalid value for $f." ) unless grep { $_ eq $v } @{ $SOURCING_ENUM{$f} };
        $out{$f} = $v;
    }
    my $km = $a->{local_km};
    if ( defined $km && $km ne '' ) {
        return ( undef, 'Distance must be a whole number of km (0-20000).' )
            unless $km =~ /^\s*\d{1,5}\s*$/ && $km <= 20000;
        $out{local_km} = 0 + $km;
    }
    else { $out{local_km} = undef }
    my $cert = $self->clean_text( $a->{certifier} );
    return ( undef, 'Certifier must be 100 characters or fewer.' ) if length($cert) > 100;
    return ( undef, q{Certifier may only contain letters, numbers, spaces and - ' & ( ) , . /} )
        if length $cert && $cert !~ m{^[\p{L}\p{N}][\p{L}\p{N} \-'&(),./]*$};
    $out{certifier}     = length $cert ? $cert : undef;
    $out{cert_verified} = defined $a->{cert_verified} && $a->{cert_verified} =~ /^(1|on|yes)$/i ? 1
                        : defined $a->{cert_verified} && $a->{cert_verified} =~ /^(0|no)$/i   ? 0 : undef;
    return ( \%out, undef );
}

# Pure: validate user preferences.
sub validate_prefs {
    my ( $self, $a ) = @_;
    my $w = $a->{ethics_weight};
    $w = 0 if !defined $w || $w eq '';
    return ( undef, 'Ethics weight must be 0-5.' ) unless $w =~ /^\d$/ && $w <= 5;
    return ( {
        prefer_organic => ( ( $a->{prefer_organic} // '' ) =~ /^(1|on|yes)$/i ? 1 : 0 ),
        avoid_feedlot  => ( ( $a->{avoid_feedlot}  // '' ) =~ /^(1|on|yes)$/i ? 1 : 0 ),
        ethics_weight  => 0 + $w,
    }, undef );
}

# Pure: factor rows that apply to a product's attributes.
sub match_factors {
    my ( $self, $p, $factors ) = @_;
    return [] unless $p;
    my %have;
    $have{$_} = $p->{$_} for grep { defined $p->{$_} } keys %SOURCING_ENUM;
    $have{local} = 'local' if defined $p->{local_km} && $p->{local_km} <= $LOCAL_KM;
    my $cat = $p->{food_category} // '';
    return [ grep {
        my $f = $_;
        ( $f->{food_category} eq 'any' || ( length $cat && $f->{food_category} eq $cat ) )
            && $f->{attribute} ne 'food_category'
            && defined $have{ $f->{attribute} } && $have{ $f->{attribute} } eq $f->{attr_value}
    } @{ $factors || [] } ];
}

# Pure: apply percent adjustments to a COPY of base nutrients. Base is never modified.
sub adjust_nutrients {
    my ( $self, $base, $factors ) = @_;
    my %adj = map { $_ => $base->{$_} } @NUTRIENTS;
    my ( %pct, @src );
    for my $f ( @{ $factors || [] } ) {
        my $j = $f->{nutrient_adj_json} or next;
        my $h = ref $j ? $j : eval { decode_json($j) } or next;
        my $used;
        for my $k ( keys %$h ) {
            next unless grep { $_ eq $k } @NUTRIENTS;
            $pct{$k} += $h->{$k};
            $used = 1;
        }
        push @src, $f->{citation} if $used;
    }
    return undef unless %pct;
    for my $k ( keys %pct ) {
        next unless defined $adj{$k};
        $adj{$k} = 0 + sprintf( '%.2f', $adj{$k} * ( 1 + $pct{$k} / 100 ) );
    }
    return { %adj, estimate => 1, pct => \%pct, citations => \@src };
}

# Pure: contamination + ethics summary for matched factors.
sub sourcing_summary {
    my ( $self, $factors ) = @_;
    my ( %risk, @eth );
    for my $f ( @{ $factors || [] } ) {
        for my $r (qw(pesticide antibiotic hormone heavy_metal)) {
            my $lvl = $f->{"${r}_risk"} or next;
            next unless exists $RISK_PTS{$lvl};
            $risk{$r} = $lvl if !defined $risk{$r} || $RISK_PTS{$lvl} > $RISK_PTS{ $risk{$r} };
        }
        push @eth, $f->{ethics_score} if defined $f->{ethics_score};
    }
    my $pen = 0;
    $pen += $RISK_PTS{$_} for values %risk;
    my $eth = @eth ? 0 + sprintf( '%.1f', eval { my $s = 0; $s += $_ for @eth; $s / @eth } ) : undef;
    return { risks => \%risk, contamination => $pen, ethics => $eth };
}

# Pure: preference-weighted sourcing score. 0 means neutral / no information.
# ethics contributes only when the user sets ethics_weight > 0 (default 0).
sub sourcing_score {
    my ( $self, $p, $summary, $prefs ) = @_;
    $p ||= {};
    $summary ||= {};
    $prefs ||= {};
    my $s = 0;
    my $w = $prefs->{ethics_weight} || 0;
    $s += $w * ( ( $summary->{ethics} // 2.5 ) - 2.5 ) / 2.5 if $w && defined $summary->{ethics};
    $s -= 0.5 * ( $summary->{contamination} || 0 );
    if ( $prefs->{prefer_organic} ) {
        my $pr = $p->{production} // '';
        $s += 1 if $pr eq 'organic_certified';
        $s -= 0.5 if $pr eq 'conventional';
    }
    $s -= 3 if $prefs->{avoid_feedlot} && ( $p->{animal_raising} // '' ) eq 'feedlot';
    return 0 + sprintf( '%.2f', $s );
}

# Pure: short display labels.
sub sourcing_badges {
    my ( $self, $p ) = @_;
    return [] unless $p;
    my @b;
    for my $f (qw(production animal_raising catch_method gmo)) {
        my $v = $p->{$f} // next;
        push @b, $BADGE{$v} if $BADGE{$v};
    }
    push @b, 'Local' if defined $p->{local_km} && $p->{local_km} <= $LOCAL_KM;
    push @b, 'Cert: ' . $p->{certifier} . ( $p->{cert_verified} ? '' : ' (unverified)' ) if $p->{certifier};
    return \@b;
}

sub list_sourcing_factors {
    my ( $self, $c ) = @_;
    return $c->stash->{hk_factors} if $c->stash->{hk_factors};
    my @out;
    if ( $self->factor_ready($c) ) {
        try {
            for my $f ( $c->model('DBEncy')->resultset('HealthKitchen::SourcingFactor')->search( {} )->all ) {
                push @out, { $f->get_columns };
            }
        }
        catch {
            $self->logging->log_with_details( $c, 'warning', __FILE__, __LINE__, 'list_sourcing_factors', "$_" );
        };
    }
    return $c->stash->{hk_factors} = \@out;
}

sub get_prefs {
    my ( $self, $c ) = @_;
    my $p = $self->get_profile($c);
    return { prefer_organic => $p->{prefer_organic} ? 1 : 0, avoid_feedlot => $p->{avoid_feedlot} ? 1 : 0,
             ethics_weight => 0 + ( $p->{ethics_weight} || 0 ) };
}

# Enrich a product hash with badges, factor summary and score.
sub _enrich_product {
    my ( $self, $prod, $factors, $prefs ) = @_;
    my $m = $self->match_factors( $prod, $factors );
    $prod->{badges}   = $self->sourcing_badges($prod);
    $prod->{summary}  = $self->sourcing_summary($m);
    $prod->{score}    = $self->sourcing_score( $prod, $prod->{summary}, $prefs );
    $prod->{factors}  = $m;
    return $prod;
}

# inventory_item_id => enriched product (for nutrition foods linked to inventory).
sub _products_by_inventory {
    my ( $self, $c ) = @_;
    return {} unless $self->product_ready($c) && $self->sourcing_cols_ready($c);
    my ( %out, $factors, $prefs );
    $factors = $self->list_sourcing_factors($c);
    $prefs   = $self->get_prefs($c);
    try {
        for my $p ( $c->model('DBEncy')->resultset('HealthKitchen::ItemProduct')->search(
                { sitename => $self->sitename($c), item_kind => 'inventory' } )->all ) {
            $out{ $p->item_id } = $self->_enrich_product( { $p->get_columns }, $factors, $prefs );
        }
    }
    catch {
        $self->logging->log_with_details( $c, 'warning', __FILE__, __LINE__, '_products_by_inventory', "$_" );
    };
    return \%out;
}

__PACKAGE__->meta->make_immutable;
1;
