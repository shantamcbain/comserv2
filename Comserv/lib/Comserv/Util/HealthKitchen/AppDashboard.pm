package Comserv::Util::HealthKitchen::AppDashboard;

# JSON for the Android HealthKitchen screen. Same facts as
# healthkitchen/index.tt + _meal_slots.tt — not a separate menu.
# Caller (Controller::Api) checks the session; allowed() checks the module.

use strict;
use warnings;

sub _log {
    my ( $c, $level, $line, $method, $msg ) = @_;
    require Comserv::Util::Logging;
    Comserv::Util::Logging->instance->log_with_details(
        $c, $level, __FILE__, $line, $method, $msg );
}

sub _s {
    my ($v) = @_;
    return '' unless defined $v;
    my $s = "$v";
    $s =~ s/[\x00-\x08\x0b\x0c\x0e-\x1f]//g;
    $s =~ s/^\s+|\s+$//g;
    return $s;
}

sub allowed {
    my ( $class, $c ) = @_;
    return 0 unless $c && $c->session->{user_id};
    my $roles = $c->session->{roles} || [];
    my @role_list = ref $roles ? @$roles : split( /\s*,\s*/, $roles );
    return 1 if grep { lc($_) eq 'admin' || lc($_) eq 'site_admin' } @role_list;

    my $ok = 0;
    my $err = '';
    eval {
        require Comserv::Util::MembershipHelper;
        $ok = Comserv::Util::MembershipHelper->new( c => $c )->can_access('healthkitchen') ? 1 : 0;
        1;
    } or do { $err = $@ || 'access check failed' };
    if ($err) {
        _log( $c, 'error', __LINE__, 'allowed', "healthkitchen access check failed: $err" );
        $ok = 0;
    }
    my $em = $c->stash->{enabled_modules};
    $ok = 1 if !$ok && ref $em eq 'HASH' && $em->{healthkitchen};
    return $ok;
}

sub _slot {
    my ($s) = @_;
    return unless ref $s eq 'HASH';
    my @recipes;
    for my $r ( @{ $s->{recipes} || [] } ) {
        next unless ref $r eq 'HASH';
        my $ings = ref $r->{ingredients} eq 'ARRAY' ? $r->{ingredients} : [];
        push @recipes, {
            id          => ( $r->{id} || 0 ) + 0,
            name        => _s( $r->{name} ),
            url         => _s( $r->{url} ),
            ingredients => [ map { _s($_) } @$ings ],
        };
    }
    return {
        key       => _s( $s->{key} ),
        kind      => _s( $s->{kind} ),
        label     => _s( $s->{label} ),
        title     => _s( $s->{title} || $s->{label} ),
        start     => _s( $s->{start} ),
        end       => _s( $s->{end} ),
        done      => $s->{done} ? 1 : 0,
        started   => _s( $s->{started} ),
        duration  => defined $s->{duration} && $s->{duration} ne '' ? $s->{duration} + 0 : undef,
        recipes   => \@recipes,
    };
}

sub _recipe {
    my ($r) = @_;
    return unless ref $r eq 'HASH';
    my @lines;
    for my $ln ( @{ $r->{lines} || [] } ) {
        next unless ref $ln eq 'HASH';
        push @lines, {
            name     => _s( $ln->{name} ),
            quantity => defined $ln->{quantity} ? _s( $ln->{quantity} ) : '',
            unit     => _s( $ln->{unit} ),
        };
    }
    return {
        id           => ( $r->{id} || 0 ) + 0,
        name         => _s( $r->{name} ),
        description  => _s( $r->{description} ),
        preparation  => _s( $r->{preparation} || $r->{instructions} ),
        servings     => defined $r->{servings} ? _s( $r->{servings} ) : '',
        lines        => \@lines,
    };
}

# Same sources as the HTML index. Dies are caught by the controller.
sub payload {
    my ( $class, $c ) = @_;
    require Comserv::Util::HealthKitchen;
    require Comserv::Util::HealthKitchen::MealSlots;
    require Comserv::Util::AppTime;

    my $hk    = Comserv::Util::HealthKitchen->new;
    my $today = Comserv::Util::AppTime->today_ymd_for($c);
    my $day   = Comserv::Util::HealthKitchen::MealSlots->day( $c, $today ) || { slots => [] };
    my $recipes = $hk->list_recipes($c) || [];
    my $short   = $hk->short_list($c) || [];

    my @slots = map { _slot($_) } @{ $day->{slots} || [] };
    my ($drink) = grep { ( $_->{kind} || '' ) eq 'drink' && @{ $_->{recipes} || [] } } @slots;
    my $morning = '';
    if ($drink) {
        my $r = $drink->{recipes}[0];
        $morning = @{ $r->{ingredients} || [] }
            ? join( ', ', @{ $r->{ingredients} } )
            : ( $r->{name} || '' );
    }

    my @need;
    for my $n (@$short) {
        next unless ref $n eq 'HASH';
        push @need, {
            name => _s( $n->{name} ),
            via  => _s( $n->{via} ),
            qty  => defined $n->{qty} ? _s( $n->{qty} ) : '',
            unit => _s( $n->{unit} ),
        };
    }

    my @out_recipes = map { _recipe($_) } @$recipes;
    splice @out_recipes, 40 if @out_recipes > 40;

    return {
        success        => 1,
        date           => _s($today),
        coffees        => ( $day->{coffees} || 0 ) + 0,
        morning        => $morning,
        inventory_mode => $hk->site_has_inventory($c) ? 1 : 0,
        timing_ready   => $day->{timing_ready} ? 1 : 0,
        slots          => \@slots,
        need           => \@need,
        recipes        => \@out_recipes,
        drinks_out     => [
            map { { name => _s( $_->{name} ), location => _s( $_->{location} ) } }
                @{ $day->{drinks_out} || [] }
        ],
    };
}

# POST from the Android screen. Same writers as the HTML forms.
sub apply {
    my ( $class, $c, $p ) = @_;
    $p = {} unless ref $p eq 'HASH';
    my $act = $p->{hk_action} // '';
    if ( $act eq 'slot' ) {
        require Comserv::Util::HealthKitchen::MealLog;
        return Comserv::Util::HealthKitchen::MealLog->slot_action(
            $c, $p->{verb}, $p->{slot}, { recipe_id => $p->{recipe_id} } );
    }
    if ( $act eq 'drink_out' ) {
        require Comserv::Util::HealthKitchen::MealLog;
        return Comserv::Util::HealthKitchen::MealLog->drink_out( $c, $p );
    }
    if ( $act eq 'meal_out' ) {
        require Comserv::Util::HealthKitchen::MealLog;
        return Comserv::Util::HealthKitchen::MealLog->meal_out( $c, $p );
    }
    if ( $act eq 'recipe_make' ) {
        require Comserv::Util::HealthKitchen;
        my $hk      = Comserv::Util::HealthKitchen->new;
        my $batches = $hk->valid_batches( $c, $p->{batches} );
        return { ok => 0, error => 'Batches must be a whole number from 1 to ' . $hk->max_batches($c) . '.' }
            unless defined $batches;
        return { ok => 0, error => 'Invalid recipe.' } unless ( $p->{recipe_id} // '' ) =~ /^\d+$/;
        return $hk->consume_recipe( $c, $p->{recipe_id}, $batches );
    }
    return { ok => 0, error => 'Unknown action.' };
}

1;
