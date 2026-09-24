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
    $c->stash->{hk_pantry_ready}  = $self->hk->pantry_ready($c) ? 1 : 0;
    $c->stash->{hk_recipe_ready}  = $self->hk->recipe_ready($c) ? 1 : 0;
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
    $c->stash(
        hk_pantry => $self->hk->list_pantry($c),
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

__PACKAGE__->meta->make_immutable;
1;
