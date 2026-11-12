package Comserv::Util::HealthKitchen::MealSlots;

# READ-ONLY. Builds a user's day of meal/drink slots from:
#   per-user slot times (user pref healthkitchen.meal_slots, keyed by site),
#   drink default recipes (by name), meal plan entries (owner + site),
#   and that day's IntakeLog rows (timing / done / coffee count).
# Every lookup is scoped to the session user + site. Nothing here writes.

use strict;
use warnings;
use Comserv::Util::HealthKitchen::SlotRecipe;

our $PREF_KEY = 'healthkitchen.meal_slots';
my $SR = 'Comserv::Util::HealthKitchen::SlotRecipe';

# Shanta's schedule doubles as the default for a user with no settings.
our @DEFAULT_SLOTS = (
    { key => 'morning_beverage', kind => 'drink', label => 'Morning beverage', start => '05:00', end => '06:00', recipe_name => 'Morning beverage' },
    { key => 'coffee_1',  kind => 'drink', label => 'Coffee',    start => '06:00', end => '06:15', recipe_name => 'Coffee' },
    { key => 'coffee_2',  kind => 'drink', label => 'Coffee',    start => '06:15', end => '06:30', recipe_name => 'Coffee' },
    { key => 'breakfast', kind => 'meal',  label => 'Breakfast', start => '10:00', end => '10:30', plan_slots => ['breakfast'] },
    { key => 'supper',    kind => 'meal',  label => 'Supper',    start => '16:00', end => '17:00', plan_slots => ['dinner'] },
);
our %PLAN_SLOTS = map { $_ => 1 } qw(breakfast lunch dinner snack);

sub _hm_ok { defined $_[0] && $_[0] =~ /\A([01]\d|2[0-3]):[0-5]\d\z/ }
sub hm_to_min { my ( $h, $m ) = split /:/, $_[1]; return $h * 60 + $m }
sub min_to_hm { sprintf '%02d:%02d', int( $_[1] / 60 ) % 24, $_[1] % 60 }

# Validates one site's slot list. Returns cleaned arrayref or undef.
sub clean_slots {
    my ( $class, $list ) = @_;
    return undef unless ref $list eq 'ARRAY' && @$list && @$list <= 20;
    my ( @out, %seen );
    for my $s (@$list) {
        return undef unless ref $s eq 'HASH';
        my $key = $s->{key} // '';
        return undef unless $key =~ /\A[a-z][a-z0-9_]{0,31}\z/ && !$seen{$key}++;
        return undef unless ( $s->{kind} // '' ) =~ /\A(meal|drink)\z/;
        return undef unless _hm_ok( $s->{start} ) && _hm_ok( $s->{end} )
            && $class->hm_to_min( $s->{end} ) > $class->hm_to_min( $s->{start} );
        my $label = $s->{label} // '';
        return undef unless $label =~ /\A[^<>\x00-\x1f]{1,60}\z/;
        my %c = ( key => $key, kind => $s->{kind}, label => $label, start => $s->{start}, end => $s->{end} );
        if ( defined $s->{recipe_name} && length $s->{recipe_name} ) {
            return undef unless $s->{recipe_name} =~ /\A[^<>\x00-\x1f]{1,120}\z/;
            $c{recipe_name} = $s->{recipe_name};
        }
        if ( $s->{plan_slots} ) {
            return undef unless ref $s->{plan_slots} eq 'ARRAY'
                && !grep { !$PLAN_SLOTS{ $_ // '' } } @{ $s->{plan_slots} };
            $c{plan_slots} = [ @{ $s->{plan_slots} } ];
        }
        push @out, \%c;
    }
    return [ sort { $a->{start} cmp $b->{start} } @out ];
}

# Whole pref value: { sitename => [slots] }.
sub valid_pref {
    my ( $class, $v ) = @_;
    return 0 unless ref $v eq 'HASH' && keys %$v <= 50;
    for my $site ( keys %$v ) {
        return 0 unless $site =~ /\A[A-Za-z0-9_.\- ]{1,64}\z/ && $class->clean_slots( $v->{$site} );
    }
    return 1;
}

sub owner {
    my ( $class, $c ) = @_;
    return { user_id => $c->session->{user_id}, username => $c->session->{username},
             sitename => ( $c->stash->{SiteName} || $c->session->{SiteName} ) };
}

sub slots_for {
    my ( $class, $c ) = @_;
    my $o = $class->owner($c);
    my $pref = eval {
        require Comserv::Util::UserPreferences;
        Comserv::Util::UserPreferences->new->get( $c, $o->{user_id}, $PREF_KEY );
    };
    my $mine = ref $pref eq 'HASH' && $o->{sitename} ? $class->clean_slots( $pref->{ $o->{sitename} } ) : undef;
    return $mine || [ map { +{%$_} } @DEFAULT_SLOTS ];
}

sub _recipe_by_name {
    my ( $class, $schema, $name, $owner ) = @_;
    return undef unless $name && $SR->_owner_ok($owner);
    my $r = eval {
        $schema->resultset('Recipe')->search(
            { 'me.name' => $name, 'me.sitename' => $owner->{sitename}, 'me.username_of_poster' => $owner->{username} },
            { order_by => 'me.id', rows => 1 } )->first;
    };
    return $r ? $SR->recipe_card( $schema, $r->id, $owner ) : undef;
}

sub _plan_entries {
    my ( $class, $schema, $owner, $date, $slots ) = @_;
    return () unless $owner->{user_id} && @$slots;
    return eval {
        $schema->resultset('HealthKitchen::MealPlanEntry')->search(
            {   'me.plan_date' => $date, 'me.meal_slot' => { -in => $slots },
                'meal_plan.user_id' => $owner->{user_id}, 'meal_plan.sitename' => $owner->{sitename},
                'meal_plan.status' => { '!=' => 'archived' } },
            { join => 'meal_plan', order_by => [ { -desc => 'meal_plan.id' }, 'me.id' ] } )->all;
    };
}

# Intake rows for the day; [] when the timing columns are not applied yet.
sub _logs {
    my ( $class, $schema, $owner, $from, $to ) = @_;
    my @rows = eval {
        $schema->resultset('HealthKitchen::IntakeLog')->search(
            { user_id => $owner->{user_id}, sitename => $owner->{sitename},
              log_date => { -between => [ $from, $to ] }, kind => { '!=' => undef } },
            { order_by => 'id' } )->all;
    };
    return ( $@ ? 0 : 1, \@rows );
}

sub day {
    my ( $class, $c, $date ) = @_;
    my $schema = $c->model('DBEncy');
    my $owner  = $class->owner($c);
    my ( $timing_ready, $logs ) = $class->_logs( $schema, $owner, $date, $date );
    my ( @cards, %seen_entry );
    for my $s ( @{ $class->slots_for($c) } ) {
        my %card = ( %$s, recipes => [] );
        if ( $s->{kind} eq 'drink' ) {
            my $r = $class->_recipe_by_name( $schema, $s->{recipe_name}, $owner );
            push @{ $card{recipes} }, $r if $r;
        }
        for my $e ( $class->_plan_entries( $schema, $owner, $date, $s->{plan_slots} || [] ) ) {
            next if $seen_entry{ $e->id }++;
            my $r = $SR->recipe_card( $schema, $e->recipe_id, $owner ) or next;
            $r->{entry_id} = $e->id;
            push @{ $card{recipes} }, $r;
        }
        my @mine = grep { ( $_->slot_key // '' ) eq $s->{key} } @$logs;
        my ($open) = grep { $_->started_at && !$_->ended_at } reverse @mine;
        my ($done) = grep { $_->ended_at } reverse @mine;
        $card{open_id}  = $open ? $open->id : undef;
        $card{started}  = $open ? substr( "" . $open->started_at, 11, 5 ) : undef;
        $card{done}     = $done ? 1 : 0;
        $card{duration} = $done ? $done->duration_min : undef;
        push @cards, \%card;
    }
    my @out_drinks = grep { ( $_->source // '' ) eq 'drink_out' } @$logs;
    my @meals_out  = grep { ( $_->source // '' ) eq 'meal_out' } @$logs;
    my $coffees = grep { ( $_->kind // '' ) eq 'drink' && ( $_->food_name // '' ) =~ /coffee/i
                         && ( ( $_->source // '' ) eq 'drink_out' || $_->ended_at ) } @$logs;
    return {
        date => $date, slots => \@cards, timing_ready => $timing_ready,
        coffees => $coffees,
        drinks_out => [ map { +{ id => $_->id, name => $_->food_name, location => $_->location } } @out_drinks ],
        meals_out  => [ map { +{ id => $_->id, description => $_->description, location => $_->location } } @meals_out ],
    };
}

# Median actual start over the last 14 days; suggest when >= 15 min off and n >= 3.
sub median { my @v = sort { $a <=> $b } @_[ 1 .. $#_ ]; return undef unless @v; my $m = int( @v / 2 ); @v % 2 ? $v[$m] : int( ( $v[ $m - 1 ] + $v[$m] ) / 2 ) }

sub suggest_from_starts {
    my ( $class, $slots, $starts ) = @_;    # $starts = { key => [ 'HH:MM', ... ] }
    my @out;
    for my $s (@$slots) {
        my @m = map { $class->hm_to_min($_) } grep { _hm_ok($_) } @{ $starts->{ $s->{key} } || [] };
        next unless @m >= 3;
        my $med = $class->median(@m);
        my $cur = $class->hm_to_min( $s->{start} );
        next unless abs( $med - $cur ) >= 15;
        push @out, { key => $s->{key}, label => $s->{label}, from => $s->{start}, to => $class->min_to_hm($med), n => scalar @m };
    }
    return \@out;
}

sub suggestions {
    my ( $class, $c, $today ) = @_;
    require Comserv::Util::AppTime;
    my $from = eval { Comserv::Util::AppTime->ymd_plus_days_for( $c, -14 ) } || $today;
    my ( $ok, $logs ) = $class->_logs( $c->model('DBEncy'), $class->owner($c), $from, $today );
    return [] unless $ok;
    my %starts;
    for my $r (@$logs) {
        next unless $r->slot_key && $r->started_at && ( $r->source // '' ) eq 'slot';
        push @{ $starts{ $r->slot_key } }, substr( "" . $r->started_at, 11, 5 );
    }
    return $class->suggest_from_starts( $class->slots_for($c), \%starts );
}

1;
