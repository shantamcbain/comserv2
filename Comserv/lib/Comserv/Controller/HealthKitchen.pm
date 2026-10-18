package Comserv::Controller::HealthKitchen;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
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
    $c->stash->{hk_sourcing_enums} = $self->hk->sourcing_enums;
}

sub index :Path('/healthkitchen') :Args(0) {
    my ( $self, $c ) = @_;
    $self->logging->log_with_details( $c, 'info', __FILE__, __LINE__, 'index',
        'HealthKitchen index' );
    $c->stash(
        hk_short   => $self->hk->short_list($c),
        hk_recipes => $self->hk->list_recipes($c),
        template   => 'healthkitchen/index.tt',
    );
}

sub pantry :Local :Args(0) {
    my ( $self, $c ) = @_;
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
        template   => 'healthkitchen/recipes.tt',
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
    my $batches = $c->req->params->{batches} || 1;
    my $res     = $self->hk->consume_recipe( $c, $recipe_id, $batches );
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
            { map { $_ => $p->{$_} } qw(item_kind item_id brand upc size sourcing_submitted food_category production animal_raising catch_method gmo local_km certifier cert_verified) } );
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
    unless ( $self->_is_admin($c) ) {
        $c->response->status(403);
        $c->response->body('Forbidden');
        $c->detach;
        return;
    }
    $self->logging->log_with_details( $c, 'info', __FILE__, __LINE__, 'history_admin',
        "Admin view of shared health history for user $subject_id" );
    $c->stash(
        hk_subject => $subject_id,
        hk_history => $self->hk->admin_shared_history( $c, $subject_id ),
        template   => 'healthkitchen/history_admin.tt',
    );
}

__PACKAGE__->meta->make_immutable;
1;
