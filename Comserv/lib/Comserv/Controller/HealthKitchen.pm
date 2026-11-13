package Comserv::Controller::HealthKitchen;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use JSON::MaybeXS qw(encode_json);
use Comserv::Util::MembershipHelper;
use Comserv::Util::HealthKitchen;

BEGIN { extends 'Catalyst::Controller'; }

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance },
);

has 'hk' => (
    is      => 'ro',
    default => sub { Comserv::Util::HealthKitchen->new },
);

# Personal wellness kitchen (not Controller::Health — that is server liveness).
# Gated by membership_service_access / MembershipHelper::can_access('healthkitchen').

sub auto :Private {
    my ( $self, $c ) = @_;
    $self->logging->log_with_details( $c, 'info', __FILE__, __LINE__, 'auto',
        'HealthKitchen auto' );

    my $user_id = $c->session->{user_id};
    unless ($user_id) {
        $c->flash->{error_msg} = 'Please log in to use Health Kitchen.';
        $c->response->redirect( $c->uri_for('/user/login') );
        $c->detach;
        return 0;
    }

    # Every Health Kitchen POST must be same-origin (scheme + host + port).
    if ( $c->req->method eq 'POST' ) {
        require Comserv::Util::OriginCheck;
        unless ( Comserv::Util::OriginCheck->request_ok($c) ) {
            $self->logging->log_with_details( $c, 'warn', __FILE__, __LINE__, 'auto',
                'HealthKitchen POST refused (cross-site) path=' . ( $c->req->path // '' ) );
            $c->res->status(403);
            $c->res->content_type('text/plain; charset=utf-8');
            $c->res->body('Request refused (cross-site).');
            $c->detach;
            return 0;
        }
    }

    my $roles = $c->session->{roles} || [];
    my @role_list = ref $roles ? @$roles : split( /\s*,\s*/, $roles );
    my $is_admin = grep { lc($_) eq 'admin' || lc($_) eq 'site_admin' } @role_list;
    if ($is_admin) {
        $c->stash->{healthkitchen_access} = 1;
        $self->_stash_mode($c);
        return 1;
    }

    my $has_access = 0;
    eval {
        my $helper = Comserv::Util::MembershipHelper->new( c => $c );
        $has_access = $helper->can_access('healthkitchen') ? 1 : 0;
    };
    if ( my $err = $@ ) {
        $self->logging->log_with_details( $c, 'error', __FILE__, __LINE__, 'auto',
            "healthkitchen access check failed: $err" );
        $has_access = 0;
    }

    my $em = $c->stash->{enabled_modules};
    if ( !$has_access && ref $em eq 'HASH' && $em->{healthkitchen} ) {
        $has_access = 1;
    }

    unless ($has_access) {
        $c->flash->{error_msg}
            = 'Add Health Kitchen to your account to use this feature.';
        $c->response->redirect( $c->uri_for('/membership/addons') );
        $c->detach;
        return 0;
    }

    $c->stash->{healthkitchen_access} = 1;
    $self->_stash_mode($c);
    return 1;
}

sub _stash_mode {
    my ( $self, $c ) = @_;
    my $inv = $self->hk->site_has_inventory($c) ? 1 : 0;
    $c->stash->{hk_has_inventory} = $inv;
    $c->stash->{hk_mode}          = $inv ? 'inventory' : 'personal';
    $c->stash->{hk_pantry_ready}   = $self->hk->pantry_ready($c) ? 1 : 0;
    $c->stash->{hk_recipe_ready}   = $self->hk->recipe_ready($c) ? 1 : 0;
    $c->stash->{hk_map_ready}      = $self->hk->map_ready($c) ? 1 : 0;
    $c->stash->{hk_symptom_ready}  = $self->hk->symptom_ready($c) ? 1 : 0;
    $c->stash->{hk_profile_ready}  = $self->hk->profile_ready($c) ? 1 : 0;
    $c->stash->{hk_sourcing_ready} = $self->hk->sourcing_cols_ready($c) ? 1 : 0;
    $c->stash->{hk_prefs_ready}    = $self->hk->prefs_cols_ready($c) ? 1 : 0;
    $c->stash->{hk_factor_ready}   = $self->hk->factor_ready($c) ? 1 : 0;
    $self->hk->ensure_sourcing_seed($c) if $c->stash->{hk_factor_ready};
    $self->hk->ensure_ency_herb_seed($c);
    $c->stash->{hk_sourcing_enums} = $self->hk->sourcing_enums;
}

# Food branch of the shared inventory category tree (for the pantry sourcing editor).
sub _food_category_options {
    my ( $self, $c ) = @_;
    require Comserv::Util::CategoryManager;
    my $o = eval { Comserv::Util::CategoryManager->new->options_for_site(
        $c->model('DBEncy'), $self->hk->sitename($c), $c->stash->{enabled_modules} || {} ) } || [];
    return [ grep { ( $_->{top} // '' ) eq 'Food' } @$o ];
}

sub index :Path('/healthkitchen') :Args(0) {
    my ( $self, $c ) = @_;
    $self->logging->log_with_details( $c, 'info', __FILE__, __LINE__, 'index',
        'HealthKitchen index' );
    if ( $c->req->method eq 'POST' && ( $c->req->params->{hk_action} // '' ) eq 'build_today' ) {
        my $res = $self->hk->build_today_plan($c);
        if ( $res->{ok} ) {
            $c->flash->{success_msg} = 'Today\'s menu saved from your pantry match.';
            $c->response->redirect( $c->uri_for( '/healthkitchen/plan/' . $res->{id} ) );
        }
        else {
            $c->flash->{error_msg} = $res->{error} || 'Could not build today\'s menu.';
            $c->response->redirect( $c->uri_for('/healthkitchen') );
        }
        $c->detach;
        return;
    }
    my $recipes = $self->hk->list_recipes($c);
    my $n = @$recipes;
    my $preview_end = $n > 5 ? 4 : ( $n ? $n - 1 : -1 );
    $c->stash(
        hk_short    => $self->hk->short_list($c),
        hk_recipes  => $preview_end >= 0 ? [ @{$recipes}[ 0 .. $preview_end ] ] : [],
        hk_recipe_n => $n,
        hk_today    => $self->hk->today_dashboard($c),
        $self->_meal_slot_stash($c),
        template    => 'healthkitchen/index.tt',
    );
}

# HealthKitchen.slots_source: 'mealslots' (default; slot cards from MealSlots)
# or 'todos' (old embedded /todo/day?filter=schedule iframe).
sub _slots_source {
    my ( $self, $c ) = @_;
    my $v = eval { $c->config->{HealthKitchen}{slots_source} } // 'mealslots';
    return $v eq 'todos' ? 'todos' : 'mealslots';
}

sub _meal_slot_stash {
    my ( $self, $c ) = @_;
    my $src = $self->_slots_source($c);
    return ( hk_slots_source => $src ) unless $src eq 'mealslots';
    require Comserv::Util::HealthKitchen::MealSlots;
    require Comserv::Util::AppTime;
    my $MS    = 'Comserv::Util::HealthKitchen::MealSlots';
    my $today = Comserv::Util::AppTime->today_ymd_for($c);
    my $day   = eval { $MS->day( $c, $today ) } || { slots => [] };
    my $sugg  = eval { $MS->suggestions( $c, $today ) } || [];
    return ( hk_slots_source => $src, hk_day => $day, hk_slot_suggestions => $sugg );
}

sub _done {
    my ( $self, $c, $res, $ok_msg ) = @_;
    if ( $c->req->params->{ajax} ) {
        $c->res->content_type('application/json; charset=utf-8');
        $c->res->status( $res->{ok} ? 200 : 400 );
        $c->res->body( encode_json( { map { $_ => $res->{$_} } grep { /^(ok|error|id|changes|pending)$/ } keys %$res } ) );
    }
    else {
        if ( $res->{ok} ) { $c->flash->{success_msg} = $ok_msg }
        else              { $c->flash->{error_msg}   = $res->{error} || 'Failed.' }
        my $back = ( $c->req->params->{return} // '' ) eq 'slots' ? '/healthkitchen/slots' : '/healthkitchen';
        $c->response->redirect( $c->uri_for($back) );
    }
    $c->detach;
}

sub _post_only {
    my ( $self, $c ) = @_;
    return 1 if $c->req->method eq 'POST';
    $c->response->redirect( $c->uri_for('/healthkitchen') );
    $c->detach;
    return 0;
}

# Per-user meal/drink slot times (user pref healthkitchen.meal_slots, by site).
sub slots :Local :Args(0) {
    my ( $self, $c ) = @_;
    require Comserv::Util::HealthKitchen::MealSlots;
    my $MS = 'Comserv::Util::HealthKitchen::MealSlots';
    if ( $c->req->method eq 'POST' ) {
        my $p = $c->req->params;
        my @list;
        for my $i ( 0 .. 19 ) {
            my $key = $p->{"key_$i"} // '';
            next unless length $key;
            next if $p->{"remove_$i"};
            push @list, { key => $key, kind => $p->{"kind_$i"}, label => $p->{"label_$i"},
                start => $p->{"start_$i"}, end => $p->{"end_$i"},
                ( length( $p->{"recipe_$i"} // '' ) ? ( recipe_name => $p->{"recipe_$i"} ) : () ),
                ( length( $p->{"plan_$i"} // '' ) ? ( plan_slots => [ grep { length } split /\s*,\s*/, $p->{"plan_$i"} ] ) : () ) };
        }
        my $clean = $MS->clean_slots( \@list );
        my $res;
        if ( !$clean ) { $res = { ok => 0, error => 'Check the slots: key a-z0-9_, kind meal/drink, HH:MM end after start, plan slots breakfast/lunch/dinner/snack.' } }
        else {
            require Comserv::Util::UserPreferences;
            my $up   = Comserv::Util::UserPreferences->new;
            my $o    = $MS->owner($c);
            my $all  = $up->get( $c, $o->{user_id}, $Comserv::Util::HealthKitchen::MealSlots::PREF_KEY ) || {};
            $all = {} unless ref $all eq 'HASH';
            $all->{ $o->{sitename} } = $clean;
            $res = $up->set_many( $c, $o->{user_id}, { $Comserv::Util::HealthKitchen::MealSlots::PREF_KEY => $all } );
        }
        $c->req->params->{return} = 'slots';
        return $self->_done( $c, $res, 'Meal times saved.' );
    }
    require Comserv::Util::AppTime;
    my $today = Comserv::Util::AppTime->today_ymd_for($c);
    $c->stash(
        hk_slots            => $MS->slots_for($c),
        hk_slot_suggestions => ( eval { $MS->suggestions( $c, $today ) } || [] ),
        template            => 'healthkitchen/slots.tt',
    );
}

# Start / Stop / Done on a slot card -> IntakeLog timing row.
sub slot_log :Local :Args(0) {
    my ( $self, $c ) = @_;
    $self->_post_only($c) or return;
    require Comserv::Util::HealthKitchen::MealLog;
    my $p   = $c->req->params;
    my $res = Comserv::Util::HealthKitchen::MealLog->slot_action( $c, $p->{action}, $p->{slot},
        { recipe_id => $p->{recipe_id} } );
    $self->_done( $c, $res, ucfirst( $p->{action} // 'logged' ) . ' logged.' );
}

# + Drink (out): count only, no inventory.
sub drink_out :Local :Args(0) {
    my ( $self, $c ) = @_;
    $self->_post_only($c) or return;
    require Comserv::Util::HealthKitchen::MealLog;
    my $res = Comserv::Util::HealthKitchen::MealLog->drink_out( $c, $c->req->params );
    $self->_done( $c, $res, 'Drink logged (no inventory change).' );
}

# + Meal out: description of a restaurant meal, no inventory.
sub meal_out :Local :Args(0) {
    my ( $self, $c ) = @_;
    $self->_post_only($c) or return;
    require Comserv::Util::HealthKitchen::MealLog;
    my $res = Comserv::Util::HealthKitchen::MealLog->meal_out( $c, $c->req->params );
    $self->_done( $c, $res, 'Meal logged (no inventory change).' );
}

# Idempotent recipe setup (Morning beverage grams + collagen, home Coffee, net weights).
sub setup_apply :Local :Args(0) {
    my ( $self, $c ) = @_;
    $self->_post_only($c) or return;
    require Comserv::Util::HealthKitchen::RecipeSetup;
    my $res = eval { Comserv::Util::HealthKitchen::RecipeSetup->apply($c) };
    unless ($res) {
        $self->logging->log_with_details( $c, 'error', __FILE__, __LINE__, 'setup_apply', "failed: $@" );
        $res = { ok => 0, error => 'Setup failed; nothing changed.' };
    }
    else {
        $self->logging->log_with_details( $c, 'info', __FILE__, __LINE__, 'setup_apply',
            'recipe setup: ' . join( '; ', @{ $res->{changes} || [] } ) . ' backup=' . ( $res->{backup} // '' ) );
    }
    $c->req->params->{return} = 'slots';
    my $msg = 'Setup applied: ' . ( join( '; ', @{ $res->{changes} || [] } ) || 'already up to date' )
        . ( @{ $res->{pending} || [] } ? '. Pending: ' . join( '; ', @{ $res->{pending} } ) : '' );
    $self->_done( $c, $res, $msg );
}

sub pantry :Local :Args(0) {
    my ( $self, $c ) = @_;
    $c->stash->{hk_food_categories} = $self->_food_category_options($c) if $c->stash->{hk_sourcing_ready};
    $self->logging->log_with_details( $c, 'info', __FILE__, __LINE__, 'pantry',
        'HealthKitchen pantry' );
    if ( $c->req->method eq 'POST' ) {
        my $res = $self->hk->add_pantry_item(
            $c,
            {
                name              => $c->req->params->{name},
                qty               => $c->req->params->{qty},
                unit              => $c->req->params->{unit},
                reorder_point     => $c->req->params->{reorder_point},
                inventory_item_id => $c->req->params->{inventory_item_id},
            }
        );
        if ( $res->{ok} ) {
            $c->flash->{success_msg} = 'Pantry item saved.';
        }
        else {
            $c->flash->{error_msg} = $res->{error} || 'Could not save pantry item.';
        }
        $c->response->redirect( $c->uri_for( $self->action_for('pantry') ) );
        $c->detach;
        return;
    }
    my $pantry = $self->hk->list_pantry($c);
    $self->hk->attach_links_and_products( $c, $pantry );
    my $etype = $c->req->params->{ency_type} || q{herb};
    my $q     = $c->req->params->{ency_q};
    $c->stash(
        hk_pantry => $pantry,
        hk_link_ready    => $self->hk->link_ready($c) ? 1 : 0,
        hk_product_ready => $self->hk->product_ready($c) ? 1 : 0,
        hk_ency_type     => $etype,
        hk_ency_q        => $q,
        hk_ency_results  => ( defined $q ? $self->hk->search_ency_entities( $c, $etype, $q ) : [] ),
        hk_link_item     => $c->req->params->{link_item},
        template  => 'healthkitchen/pantry.tt',
    );
}

sub recipes :Local :Args(0) {
    my ( $self, $c ) = @_;
    $self->logging->log_with_details( $c, 'info', __FILE__, __LINE__, 'recipes',
        'HealthKitchen recipes' );
    $c->stash(
        hk_recipes => $self->hk->list_recipes($c),
        hk_max_batches => $self->hk->max_batches($c),
        template   => 'healthkitchen/recipes.tt',
    );
}

sub recipe_form :Local :Args(0) {
    my ( $self, $c ) = @_;
    my $id = $c->req->params->{id};
    my $form = {};
    if ( defined $id && $id =~ /^\d+$/ ) {
        $form = $self->hk->recipe_for_edit( $c, $id );
        unless ($form) {
            $c->flash->{error_msg} = 'Recipe not found, or you cannot edit it.';
            $c->response->redirect( $c->uri_for( $self->action_for('recipes') ) );
            $c->detach;
            return;
        }
    }
    $self->logging->log_with_details( $c, 'info', __FILE__, __LINE__, 'recipe_form',
        'HealthKitchen recipe form id=' . ( $form->{id} || 'new' ) );
    $c->stash(
        hk_recipe_form => $form,
        template       => 'healthkitchen/recipe_form.tt',
    );
}

sub recipe_save :Local :Args(0) {
    my ( $self, $c ) = @_;
    unless ( $c->req->method eq 'POST' ) {
        $c->response->redirect( $c->uri_for( $self->action_for('recipe_form') ) );
        $c->detach;
        return;
    }
    my $res = $self->hk->save_recipe( $c, { %{ $c->req->params } } );
    if ( $res->{ok} ) {
        $c->flash->{success_msg} = $res->{created} ? 'Recipe added.' : 'Recipe saved.';
        my $detail = $self->action_for('recipe');
        $c->response->redirect(
            $detail
            ? $c->uri_for( $detail, [ $res->{id} ] )
            : $c->uri_for( $self->action_for('recipes') )
        );
    }
    else {
        $c->flash->{error_msg} = $res->{error} || 'Could not save the recipe.';
        my $id = $c->req->params->{id};
        $c->response->redirect( $c->uri_for(
            $self->action_for('recipe_form'),
            ( defined $id && $id =~ /^\d+$/ ) ? { id => $id } : ()
        ) );
    }
    $c->detach;
}

sub recipe :Local :Args(1) {
    my ( $self, $c, $recipe_id ) = @_;
    $self->logging->log_with_details( $c, 'info', __FILE__, __LINE__, 'recipe',
        "HealthKitchen recipe $recipe_id" );
    require Comserv::Util::HealthKitchen::RecipeDetail;
    my $detail = Comserv::Util::HealthKitchen::RecipeDetail->detail( $c, $recipe_id );
    unless ($detail) {
        $c->flash->{error_msg} = 'Recipe not found.';
        $c->response->redirect( $c->uri_for( $self->action_for('recipes') ) );
        $c->detach;
        return;
    }
    $c->stash(
        hk_recipe      => $detail,
        hk_max_batches => $self->hk->max_batches($c),
        template       => 'healthkitchen/recipe.tt',
    );
}

sub seed_morning :Local :Args(0) {
    my ( $self, $c ) = @_;
    $self->logging->log_with_details( $c, 'info', __FILE__, __LINE__, 'seed_morning',
        'HealthKitchen seed_morning method=' . ( $c->req->method || '' ) );
    unless ( $c->req->method eq 'POST' ) {
        $c->response->redirect( $c->uri_for( $self->action_for('recipes') ) );
        $c->detach;
        return;
    }
    my $res = $self->hk->seed_morning_drink($c);
    if ( $res->{ok} ) {
        $c->flash->{success_msg} = $res->{existed}
            ? 'Morning turmeric coffee recipe already exists.'
            : 'Seeded morning turmeric coffee recipe.';
    }
    else {
        $c->flash->{error_msg} = $res->{error} || 'Seed failed.';
    }
    $c->response->redirect( $c->uri_for( $self->action_for('recipes') ) );
    $c->detach;
}

sub recipe_make :Local :Args(1) {
    my ( $self, $c, $recipe_id ) = @_;
    unless ( $c->req->method eq 'POST' ) {
        $c->response->redirect( $c->uri_for( $self->action_for('recipes') ) );
        $c->detach;
        return;
    }
    my $ajax = $c->req->params->{ajax} ? 1 : 0;
    # CSRF: the app has no shared token helper, so POSTs must be same-origin
    # (scheme + host + port; absent/null/malformed refused). Shared with Calendar.
    require Comserv::Util::OriginCheck;
    my $deny = !Comserv::Util::OriginCheck->request_ok($c)
        ? [ 403, 'Request refused (cross-site).' ]
        : !defined( $self->hk->valid_batches( $c, $c->req->params->{batches} ) )
        ? [ 400, 'Batches must be a whole number from 1 to ' . $self->hk->max_batches($c) . '.' ]
        : !( defined $recipe_id && $recipe_id =~ /^\d+$/ )
        ? [ 400, 'Invalid recipe.' ]
        : undef;
    if ($deny) {
        $self->logging->log_with_details( $c, 'warn', __FILE__, __LINE__, 'recipe_make',
            "recipe_make refused: $deny->[1]" );
        if ($ajax) {
            $c->res->status( $deny->[0] );
            $c->res->content_type('application/json; charset=utf-8');
            $c->res->body( encode_json( { ok => 0, error => $deny->[1] } ) );
        }
        else {
            $c->flash->{error_msg} = $deny->[1];
            $c->response->redirect( $c->uri_for( $self->action_for('recipes') ) );
        }
        $c->detach;
        return;
    }
    my $batches = $self->hk->valid_batches( $c, $c->req->params->{batches} );
    my $res     = $self->hk->consume_recipe( $c, $recipe_id, $batches );
    if ($ajax) {
        # In-place "Mark made" from a Health Kitchen day card (hk-recipe-confirm.js).
        $c->res->content_type('application/json; charset=utf-8');
        $c->res->body( encode_json( {
            ok       => $res->{ok} ? 1 : 0,
            name     => $res->{name},
            via      => $res->{via},
            deducted => $res->{deducted} || [],
            skipped  => $res->{skipped}  || [],
            ( $res->{error} ? ( error => "$res->{error}" ) : () ),
        } ) );
        $c->detach;
        return;
    }
    if ( $res->{ok} ) {
        my $via = $res->{via} eq 'inventory'
            ? 'site inventory (reorder short list)'
            : 'personal pantry';
        $c->flash->{success_msg}
            = 'Marked "' . ( $res->{name} || 'recipe' ) . "\" as made. Deducted from $via.";
    }
    else {
        $c->flash->{error_msg} = $res->{error} || 'Could not mark recipe as made.';
    }
    if ( ( $c->req->params->{return} // '' ) eq 'home' ) {
        $c->response->redirect( $c->uri_for('/healthkitchen') );
        $c->detach;
        return;
    }
    $c->response->redirect( $c->uri_for( $self->action_for('recipes') ) );
    $c->detach;
}

sub pantry_map :Local :Args(0) {
    my ( $self, $c ) = @_;
    $self->logging->log_with_details( $c, 'info', __FILE__, __LINE__, 'pantry_map',
        'HealthKitchen pantry_map method=' . ( $c->req->method || '' ) );
    unless ( $c->req->method eq 'POST' ) {
        $c->response->redirect( $c->uri_for( $self->action_for('pantry') ) );
        $c->detach;
        return;
    }
    my $res = $self->hk->upsert_ency_map(
        $c,
        {
            inventory_item_id => $c->req->params->{inventory_item_id},
            herb_id           => $c->req->params->{herb_id},
            organism_id       => $c->req->params->{organism_id},
            animal_id         => $c->req->params->{animal_id},
            insect_id         => $c->req->params->{insect_id},
            formula_id        => $c->req->params->{formula_id},
            unlink            => $c->req->params->{unlink},
        }
    );
    if ( $res->{ok} ) {
        $c->flash->{success_msg} = $c->req->params->{unlink} ? 'ENCY link removed.' : 'ENCY link saved.';
    }
    else {
        $c->flash->{error_msg} = $res->{error} || 'Could not save ENCY link.';
    }
    $c->response->redirect( $c->uri_for( $self->action_for('pantry') ) );
    $c->detach;
}

# POST: hk_action = link | unlink | product. Links pantry/inventory items to ENCY
# herbs, animals and constituents; stores brand / UPC / size.
sub pantry_link :Local :Args(0) {
    my ( $self, $c ) = @_;
    $self->logging->log_with_details( $c, 'info', __FILE__, __LINE__, 'pantry_link',
        'HealthKitchen pantry_link method=' . ( $c->req->method || '' ) );
    unless ( $c->req->method eq 'POST' ) {
        $c->response->redirect( $c->uri_for( $self->action_for('pantry') ) );
        $c->detach;
        return;
    }
    my $p      = $c->req->params;
    my $action = $p->{hk_action} || 'link';
    my $res;
    if ( $action eq 'unlink' ) {
        $res = $self->hk->remove_ency_link( $c, $p->{link_id} );
    }
    elsif ( $action eq 'product' ) {
        $res = $self->hk->save_item_product( $c,
            { map { $_ => $p->{$_} } qw(item_kind item_id brand upc size sourcing_submitted food_category_id production animal_raising catch_method gmo local_km certifier cert_verified) } );
    }
    else {
        $res = $self->hk->add_ency_link( $c,
            { map { $_ => $p->{$_} } qw(item_kind item_id entity_type entity_id) } );
    }
    if ( $res->{ok} ) {
        my $msg = { unlink => 'ENCY link removed.', product => 'Product details saved.' }->{$action}
            || 'ENCY link saved.';
        $msg .= ' (UPC check digit does not validate; please double-check.)'
            if $action eq 'product' && defined $res->{upc_check} && !$res->{upc_check};
        $c->flash->{success_msg} = $msg;
    }
    else {
        $c->flash->{error_msg} = $res->{error} || 'Could not save.';
    }
    $c->response->redirect( $c->uri_for( $self->action_for('pantry') ) );
    $c->detach;
}

sub symptoms :Local :Args(0) {
    my ( $self, $c ) = @_;
    $self->logging->log_with_details( $c, 'info', __FILE__, __LINE__, 'symptoms',
        'HealthKitchen symptoms' );
    if ( $c->req->method eq 'POST' ) {
        my $action = $c->req->params->{hk_action} || 'add';
        my $res;
        if ( $action eq 'resolve' ) {
            $res = $self->hk->resolve_symptom( $c, $c->req->params->{id} );
        }
        elsif ( $action eq q{new} ) {
            $res = $self->hk->add_user_symptom(
                $c,
                {
                    name        => $c->req->params->{new_name},
                    description => $c->req->params->{new_description},
                    severity    => $c->req->params->{severity},
                }
            );
            if ( $res->{ok} ) {
                $c->flash->{success_msg} = $res->{existing}
                    ? q{That symptom already exists in ENCY; set active.}
                    : $res->{duplicate}
                    ? q{You already submitted that symptom; it is awaiting review.}
                    : q{Thanks. Your symptom was sent for staff review and shows as pending until approved.};
                $c->response->redirect( $c->uri_for( $self->action_for(q{symptoms}) ) );
                $c->detach;
                return;
            }
        }
        elsif ( $action eq 'profile' ) {
            $res = $self->hk->save_profile(
                $c,
                {
                    diet_flags => $c->req->params->{diet_flags},
                    allergies  => $c->req->params->{allergies},
                    goals      => $c->req->params->{goals},
                    ( $c->req->params->{prefs_submitted}
                        ? ( prefs_submitted => 1, map { $_ => $c->req->params->{$_} } qw(prefer_organic avoid_feedlot ethics_weight) )
                        : () ),
                }
            );
        }
        else {
            $res = $self->hk->set_active_symptom(
                $c,
                {
                    symptom_id => $c->req->params->{symptom_id},
                    severity   => $c->req->params->{severity},
                }
            );
        }
        if ( $res->{ok} ) {
            $c->flash->{success_msg} = 'Saved.';
        }
        else {
            $c->flash->{error_msg} = $res->{error} || 'Could not save.';
        }
        $c->response->redirect( $c->uri_for( $self->action_for('symptoms') ) );
        $c->detach;
        return;
    }
    my $active = $self->hk->list_active_symptoms($c);
    $c->stash(
        hk_profile  => $self->hk->get_profile($c),
        hk_active   => $active,
        hk_pending_symptoms => $self->hk->list_pending_symptoms_for_user($c),
        hk_symptoms => $self->hk->list_ency_symptoms($c),
        hk_match    => $self->hk->match_for_symptoms(
            $c, { symptom_ids => [ map { $_->{symptom_id} } @$active ] }
        ),
        template => 'healthkitchen/symptoms.tt',
    );
}

sub plan :Local :Args(1) {
    my ( $self, $c, $id ) = @_;
    $self->logging->log_with_details( $c, 'info', __FILE__, __LINE__, 'plan',
        "HealthKitchen plan id=$id" );
    unless ( $id && $id =~ /^\d+$/ ) {
        $c->flash->{error_msg} = 'Plan not found.';
        $c->response->redirect( $c->uri_for('/healthkitchen') );
        $c->detach;
        return;
    }
    if ( $c->req->method eq 'POST' && ( $c->req->params->{hk_action} // '' ) eq 'activity_done' ) {
        my $res = $self->hk->set_activity_done(
            $c, $id, $c->req->params->{activity_id}, $c->req->params->{done} ? 1 : 0
        );
        if ( $c->req->params->{ajax} ) {
            $c->res->status( $res->{ok} ? 200 : 400 );
            $c->res->content_type('application/json; charset=utf-8');
            $c->res->body( encode_json($res) );
            $c->detach;
            return;
        }
        if ( $res->{ok} ) {
            $c->flash->{success_msg} = $res->{done} ? 'Marked done.' : 'Cleared.';
        }
        else {
            $c->flash->{error_msg} = $res->{error} || 'Could not update activity.';
        }
        $c->response->redirect( $c->uri_for( '/healthkitchen/plan/' . $id ) );
        $c->detach;
        return;
    }
    my $plan = $self->hk->load_plan( $c, $id );
    unless ($plan) {
        $c->flash->{error_msg} = 'Plan not found.';
        $c->response->redirect( $c->uri_for('/healthkitchen') );
        $c->detach;
        return;
    }
    $c->stash(
        hk_plan  => $plan,
        template => 'healthkitchen/plan.tt',
    );
}

# POST: build the whole-food week plan (recipes + 7-day meal plan) from this site's inventory.
sub week_plan :Local :Args(0) {
    my ( $self, $c ) = @_;
    $self->logging->log_with_details( $c, 'info', __FILE__, __LINE__, 'week_plan', 'HealthKitchen week plan' );
    unless ( $c->req->method eq 'POST' && $c->session->{user_id} && $self->hk->meal_plan_ready($c) ) {
        $c->flash->{error_msg} = 'Log in and use the form to build a week plan.';
        $c->response->redirect( $c->uri_for( $self->action_for('mealplans') ) );
        $c->detach;
        return;
    }
    my $start = $c->req->params->{start_date} // '';
    $start = '' unless $start =~ /^\d{4}-\d{2}-\d{2}$/;
    require Comserv::Util::HealthKitchen::WeekPlan;
    my $res = eval {
        Comserv::Util::HealthKitchen::WeekPlan::build_week( $c->model('DBEncy')->schema,
            site => $self->hk->sitename($c), user_id => $c->session->{user_id},
            username => $c->session->{username}, start_date => $start || undef );
    };
    if ($res) {
        my @need = map { $_->{label} } grep { !$_->{optional} } @{ $res->{shopping} };
        $c->flash->{success_msg} = "Week plan ready: $res->{recipes_created} new recipes, $res->{entries_created} meals."
            . ( @need ? ' Shopping list: ' . join( ', ', @need ) . '.' : '' );
    }
    else {
        $self->logging->log_with_details( $c, 'error', __FILE__, __LINE__, 'week_plan', "failed: $@" );
        $c->flash->{error_msg} = 'Could not build the week plan.';
    }
    $c->response->redirect( $res && $res->{plan_id}
        ? $c->uri_for( $self->action_for('mealplan'), $res->{plan_id} )
        : $c->uri_for( $self->action_for('mealplans') ) );
    $c->detach;
}

sub mealplans :Local :Args(0) {
    my ( $self, $c ) = @_;
    $self->logging->log_with_details( $c, 'info', __FILE__, __LINE__, 'mealplans',
        'HealthKitchen meal plans' );
    if ( $c->req->method eq 'POST' ) {
        my $p   = $c->req->params;
        my $res = $self->hk->create_meal_plan( $c,
            { name => $p->{name}, start_date => $p->{start_date}, end_date => $p->{end_date} } );
        if ( $res->{ok} ) {
            $c->flash->{success_msg} = 'Meal plan created.';
            $c->response->redirect( $c->uri_for( $self->action_for('mealplan'), $res->{id} ) );
        }
        else {
            $c->flash->{error_msg} = $res->{error};
            $c->response->redirect( $c->uri_for( $self->action_for('mealplans') ) );
        }
        $c->detach;
        return;
    }
    $c->stash(
        hk_meal_ready  => $self->hk->meal_plan_ready($c) ? 1 : 0,
        hk_plans       => $self->hk->list_meal_plans($c),
        hk_suggestions => $self->hk->suggest_recipes_from_stock($c),
        template       => 'healthkitchen/mealplans.tt',
    );
}

sub mealplan :Local :Args(1) {
    my ( $self, $c, $plan_id ) = @_;
    $self->logging->log_with_details( $c, 'info', __FILE__, __LINE__, 'mealplan',
        "HealthKitchen meal plan $plan_id" );
    if ( $c->req->method eq 'POST' ) {
        my $p = $c->req->params;
        my $res = ( $p->{hk_action} // '' ) eq 'delete'
            ? $self->hk->delete_meal_entry( $c, $plan_id, $p->{entry_id} )
            : $self->hk->add_meal_entry( $c, $plan_id, {
                  plan_date => $p->{plan_date}, meal_slot => $p->{meal_slot},
                  recipe_id => $p->{recipe_id}, custom_name => $p->{custom_name},
                  servings  => $p->{servings} } );
        if   ( $res->{ok} ) { $c->flash->{success_msg} = 'Saved.' }
        else                { $c->flash->{error_msg}   = $res->{error} || 'Could not save.' }
        $c->response->redirect( $c->uri_for( $self->action_for('mealplan'), $plan_id ) );
        $c->detach;
        return;
    }
    my $plan = $self->hk->get_meal_plan( $c, $plan_id );
    unless ($plan) {
        $c->flash->{error_msg} = 'Meal plan not found.';
        $c->response->redirect( $c->uri_for( $self->action_for('mealplans') ) );
        $c->detach;
        return;
    }
    $c->stash(
        hk_plan    => $plan,
        hk_recipes => $self->hk->meal_plan_recipes($c)->{allowed},
        template   => 'healthkitchen/mealplan.tt',
    );
}

sub nutrition :Local :Args(0) {
    my ( $self, $c ) = @_;
    $self->logging->log_with_details( $c, 'info', __FILE__, __LINE__, 'nutrition',
        'HealthKitchen nutrition' );
    my @lt = localtime;
    my $today = sprintf( '%04d-%02d-%02d', $lt[5] + 1900, $lt[4] + 1, $lt[3] );
    my $date = $self->hk->_clean_date( $c->req->params->{date} ) || $today;
    if ( $c->req->method eq 'POST' ) {
        my $p = $c->req->params;
        my $act = $p->{hk_action} // 'log';
        my $res = $act eq 'food'   ? $self->hk->add_food( $c, $p )
                : $act eq 'delete' ? $self->hk->delete_intake( $c, $p->{id} )
                :                    $self->hk->log_intake( $c, { %$p, log_date => $date } );
        if   ( $res->{ok} ) { $c->flash->{success_msg} = 'Saved.' }
        else                { $c->flash->{error_msg}   = $res->{error} || 'Could not save.' }
        $c->response->redirect( $c->uri_for( $self->action_for('nutrition'), { date => $date } ) );
        $c->detach;
        return;
    }
    my $rows = $self->hk->intake_for_day( $c, $date );
    $c->stash(
        hk_nut_ready => $self->hk->nutrition_ready($c) ? 1 : 0,
        hk_date      => $date,
        hk_foods     => $self->hk->list_foods($c),
        hk_intake    => $rows,
        hk_totals    => $self->hk->daily_totals($rows),
        template     => 'healthkitchen/nutrition.tt',
    );
}


sub recipes_suggest :Local :Args(0) {
    my ( $self, $c ) = @_;
    $self->logging->log_with_details( $c, 'info', __FILE__, __LINE__, 'recipes_suggest',
        'HealthKitchen AI recipe suggestion' );
    unless ( $c->req->method eq 'POST' ) {
        $c->response->redirect( $c->uri_for( $self->action_for('recipes') ) );
        $c->detach;
        return;
    }
    my $res = $self->hk->generate_ai_recipes( $c, { count => 3 } );
    if ( $res->{ok} ) {
        $c->flash->{success_msg} = scalar( @{ $res->{ids} } )
            . ' AI recipe draft(s) added from your stock. Please review them before cooking.';
    }
    else {
        $c->flash->{error_msg} = $res->{error};
    }
    $c->response->redirect( $c->uri_for( $self->action_for('recipes') ) );
    $c->detach;
}

sub _is_staff {
    my ( $self, $c ) = @_;
    my $roles = $c->session->{roles} || [];
    my @r = ref $roles ? @$roles : split( /\s*,\s*/, $roles );
    return ( grep { lc($_) =~ /^(admin|site_admin|staff|editor|moderator)$/ } @r ) ? 1 : 0;
}

# Staff review queue for user-submitted ENCY additions.
sub review :Local :Args(0) {
    my ( $self, $c ) = @_;
    $self->logging->log_with_details( $c, 'info', __FILE__, __LINE__, 'review',
        'HealthKitchen review queue method=' . ( $c->req->method || '' ) );
    unless ( $self->_is_staff($c) ) {
        $c->flash->{error_msg} = 'Staff only.';
        $c->response->redirect( $c->uri_for( $self->action_for('symptoms') ) );
        $c->detach;
        return;
    }
    if ( $c->req->method eq 'POST' ) {
        my $p   = $c->req->params;
        my $res = $self->hk->review_pending( $c, { id => $p->{id}, decision => $p->{decision}, notes => $p->{notes} } );
        if ( $res->{ok} ) {
            $c->flash->{success_msg} = $res->{decision} eq 'approved'
                ? ( $res->{created} ? 'Approved; ENCY symptom created and activated for the user.'
                                    : 'Approved; linked to existing ENCY symptom and activated for the user.' )
                : 'Rejected.';
        }
        else { $c->flash->{error_msg} = $res->{error} || 'Review failed.' }
        $c->response->redirect( $c->uri_for( $self->action_for('review') ) );
        $c->detach;
        return;
    }
    my $status = $c->req->params->{status} || 'pending';
    $c->stash(
        hk_pending_ready => $self->hk->pending_ready($c) ? 1 : 0,
        hk_review_status => $status,
        hk_review_rows   => $self->hk->list_pending_review( $c, $status ),
        template         => 'healthkitchen/review.tt',
    );
}

sub _is_admin {
    my ( $self, $c ) = @_;
    my $roles = $c->session->{roles} || [];
    my @r = ref $roles ? @$roles : split( /\s*,\s*/, $roles );
    return ( grep { lc($_) eq 'admin' || lc($_) eq 'site_admin' } @r ) ? 1 : 0;
}

sub history :Local :Args(0) {
    my ( $self, $c ) = @_;
    $self->logging->log_with_details( $c, 'info', __FILE__, __LINE__, 'history',
        'HealthKitchen health history' );
    if ( $c->req->method eq 'POST' ) {
        my $p   = $c->req->params;
        my $act = $p->{hk_action} // '';
        my $res = $act eq 'consent'    ? $self->hk->grant_consent($c)
                : $act eq 'revoke'     ? $self->hk->revoke_consent($c)
                : $act eq 'chart'      ? $self->hk->save_chart( $c, $p )
                : $act eq 'delete'     ? $self->hk->delete_history( $c, $p->{id} )
                : $act eq 'delete_all' ? $self->hk->delete_all_history( $c, $p->{confirm} )
                :                        $self->hk->save_history( $c, $p );
        if ( $res->{ok} ) {
            $c->flash->{success_msg} = $act eq 'delete_all' ? "Deleted all health history ($res->{deleted} entries) and consent."
                                     : $act eq 'revoke'     ? 'Consent revoked. Your history is no longer used. You can delete it below.'
                                     :                        'Saved.';
        }
        else {
            $c->flash->{error_msg} = $res->{error} || 'Could not save.';
        }
        $c->response->redirect( $c->uri_for( $self->action_for('history') ) );
        $c->detach;
        return;
    }
    my $ready = $self->hk->history_ready($c) ? 1 : 0;
    my $consent = $ready ? $self->hk->active_consent($c) : undef;
    my $edit_id = $c->req->params->{edit};
    my $hist = $consent ? $self->hk->list_history($c) : [];
    my ($edit) = $edit_id ? grep { $_->{id} == $edit_id } @$hist : ();
    $c->stash(
        hk_hist_ready => $ready,
        hk_consent    => $consent ? 1 : 0,
        hk_history    => $hist,
        hk_edit       => $edit,
        hk_chart      => $consent ? $self->hk->get_chart($c) : {},
        hk_types      => [@Comserv::Util::HealthKitchen::HISTORY_TYPES],
        hk_statuses   => [@Comserv::Util::HealthKitchen::HISTORY_STATUS],
        template      => 'healthkitchen/history.tt',
    );
}

sub history_export :Local :Args(0) {
    my ( $self, $c ) = @_;
    my $fmt = ( $c->req->params->{format} // 'json' ) eq 'csv' ? 'csv' : 'json';
    unless ( $self->hk->active_consent($c) ) {
        $c->flash->{error_msg} = 'No active health history to export.';
        $c->response->redirect( $c->uri_for( $self->action_for('history') ) );
        $c->detach;
        return;
    }
    $c->response->content_type( $fmt eq 'csv' ? 'text/csv; charset=utf-8' : 'application/json; charset=utf-8' );
    $c->response->header( 'Content-Disposition' => "attachment; filename=health_history.$fmt" );
    $c->response->header( 'Cache-Control' => 'no-store' );
    $c->response->body( $self->hk->export_history( $c, $fmt ) );
}

sub history_admin :Local :Args(1) {
    my ( $self, $c, $subject_id ) = @_;
    $self->logging->log_with_details( $c, 'warn', __FILE__, __LINE__, 'history_admin',
        "Refused history_admin for subject $subject_id; no practitioner grant exists" );
    $c->response->status(403);
    $c->response->body('Only the chart owner can see this. No practitioner has been granted access.');
    $c->detach;
    return;
}

__PACKAGE__->meta->make_immutable;
1;
