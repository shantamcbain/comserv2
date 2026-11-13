package Comserv::Util::HealthKitchen::MealLog;

# Writes hk_intake_log rows for meal slots (Start / Stop / Done) and quick
# adds (+ Drink out: count only; + Meal out: described meal). No inventory
# change here: "Mark made" stays /healthkitchen/recipe_make (consume_recipe).
# All rows are the session user's + site. Callers check OriginCheck (POST).

use strict;
use warnings;
use Comserv::Util::HealthKitchen::MealSlots;
my $MS = 'Comserv::Util::HealthKitchen::MealSlots';

sub _now {
    my ( $class, $c ) = @_;
    require Comserv::Util::AppTime;
    my $dt = Comserv::Util::AppTime->now_user_dt($c);
    return ( $dt->ymd, $dt->ymd . ' ' . $dt->hms );
}

sub _rs { $_[1]->model('DBEncy')->resultset('HealthKitchen::IntakeLog') }

sub _slot {
    my ( $class, $c, $key ) = @_;
    return undef unless defined $key && $key =~ /\A[a-z][a-z0-9_]{0,31}\z/;
    my ($s) = grep { $_->{key} eq $key } @{ $MS->slots_for($c) };
    return $s;
}

sub _open_row {
    my ( $class, $c, $o, $date, $key ) = @_;
    return $class->_rs($c)->search(
        { user_id => $o->{user_id}, sitename => $o->{sitename}, log_date => $date,
          slot_key => $key, source => 'slot', ended_at => undef, started_at => { '!=' => undef } },
        { order_by => { -desc => 'id' }, rows => 1 } )->first;
}

sub _minutes {
    my ( $class, $from, $to ) = @_;
    return undef unless ref $from && $from->can('epoch');
    my $f = $from->epoch;
    require DateTime;
    my ( $Y, $M, $D, $h, $m, $s ) = $to =~ /(\d+)-(\d+)-(\d+) (\d+):(\d+):(\d+)/;
    my $t = DateTime->new( year => $Y, month => $M, day => $D, hour => $h, minute => $m, second => $s,
                           time_zone => $from->time_zone );
    my $d = int( ( $t->epoch - $f ) / 60 + 0.5 );
    return $d < 0 ? 0 : $d;
}

# action: start | stop | done. Returns { ok, error?, id? }.
sub slot_action {
    my ( $class, $c, $action, $key, $args ) = @_;
    my $o = $MS->owner($c);
    return { ok => 0, error => 'Please log in.' } unless $o->{user_id} && $o->{sitename};
    return { ok => 0, error => 'Unknown action.' } unless ( $action // '' ) =~ /\A(start|stop|done)\z/;
    my $slot = $class->_slot( $c, $key ) or return { ok => 0, error => 'Unknown slot.' };
    my ( $date, $now ) = $class->_now($c);
    my ( $recipe_id, $entry_id, $name ) = $class->_slot_recipe( $c, $slot, $date, $args );
    my $res = eval {
        my $open = $class->_open_row( $c, $o, $date, $key );
        if ( $action eq 'start' ) {
            return { ok => 1, id => $open->id, already => 1 } if $open;
            my $row = $class->_rs($c)->create( {
                user_id => $o->{user_id}, sitename => $o->{sitename}, log_date => $date,
                meal_slot => ( $slot->{kind} eq 'meal' ? 'meal' : 'drink' ), kind => $slot->{kind},
                slot_key => $key, recipe_id => $recipe_id, meal_plan_entry_id => $entry_id,
                food_name => $name, servings => 1, started_at => $now, source => 'slot' } );
            return { ok => 1, id => $row->id };
        }
        if ($open) {
            $open->update( { ended_at => $now, duration_min => $class->_minutes( $open->started_at, $now ) } );
            return { ok => 1, id => $open->id };
        }
        return { ok => 0, error => 'Not started.' } if $action eq 'stop';
        my $row = $class->_rs($c)->create( {
            user_id => $o->{user_id}, sitename => $o->{sitename}, log_date => $date,
            meal_slot => ( $slot->{kind} eq 'meal' ? 'meal' : 'drink' ), kind => $slot->{kind},
            slot_key => $key, recipe_id => $recipe_id, meal_plan_entry_id => $entry_id,
            food_name => $name, servings => 1, started_at => $now, ended_at => $now,
            duration_min => 0, source => 'slot' } );
        return { ok => 1, id => $row->id };
    };
    return $res if $res;
    return { ok => 0, error => 'Could not log (has Schema Compare added the IntakeLog timing columns?).' };
}

# Recipe for the log row: an explicit recipe_id must be one of this slot's
# own (owner+site scoped) cards; otherwise the first card.
sub _slot_recipe {
    my ( $class, $c, $slot, $date, $args ) = @_;
    my $day = $MS->day( $c, $date );
    my ($card) = grep { $_->{key} eq $slot->{key} } @{ $day->{slots} };
    my @r = $card ? @{ $card->{recipes} } : ();
    my $want = ( $args && ( $args->{recipe_id} // '' ) =~ /\A\d+\z/ ) ? $args->{recipe_id} : undef;
    my ($r) = $want ? grep { $_->{id} == $want } @r : @r;
    return ( $r ? ( $r->{id}, $r->{entry_id}, $r->{name} ) : ( undef, undef, $slot->{label} ) );
}

sub _clean_text {
    my ( $class, $v, $max ) = @_;
    $v //= '';
    $v =~ s/[\x00-\x08\x0b\x0c\x0e-\x1f]//g;
    $v =~ s/^\s+|\s+$//g;
    return length $v ? substr( $v, 0, $max ) : undef;
}

# + Drink out: counts only (coffee at a meeting / coffee shop). No inventory.
sub drink_out {
    my ( $class, $c, $args ) = @_;
    my $o = $MS->owner($c);
    return { ok => 0, error => 'Please log in.' } unless $o->{user_id} && $o->{sitename};
    my $what = $class->_clean_text( $args->{what}, 60 ) // 'Coffee';
    my $where = $class->_clean_text( $args->{location}, 255 );
    my ( $date, $now ) = $class->_now($c);
    my $id = eval {
        $class->_rs($c)->create( {
            user_id => $o->{user_id}, sitename => $o->{sitename}, log_date => $date,
            meal_slot => 'drink', kind => 'drink', food_name => "$what (out)", servings => 1,
            started_at => $now, ended_at => $now, duration_min => 0,
            source => 'drink_out', location => $where } )->id;
    };
    return $id ? { ok => 1, id => $id } : { ok => 0, error => 'Could not log drink.' };
}

# + Meal out: description of what was eaten (typed, dictated or from Chat with AI).
sub meal_out {
    my ( $class, $c, $args ) = @_;
    my $o = $MS->owner($c);
    return { ok => 0, error => 'Please log in.' } unless $o->{user_id} && $o->{sitename};
    my $desc = $class->_clean_text( $args->{description}, 4000 )
        or return { ok => 0, error => 'Describe what you ate.' };
    my $where = $class->_clean_text( $args->{location}, 255 );
    my ( $date, $now ) = $class->_now($c);
    my $name = substr( $desc, 0, 80 );
    my $row = eval {
        $class->_rs($c)->create( {
            user_id => $o->{user_id}, sitename => $o->{sitename}, log_date => $date,
            meal_slot => 'meal', kind => 'meal', food_name => $name, servings => 1,
            started_at => $now, ended_at => $now, duration_min => 0,
            source => 'meal_out', location => $where, description => $desc } );
    };
    return { ok => 0, error => 'Could not log meal.' } unless $row;
    $class->nutrition_estimate_hook( $c, $row );
    return { ok => 1, id => $row->id };
}

# HOOK (later): AI nutrition estimate for a described meal. Should fill the
# IntakeLog nutrient columns (calories, protein_g, ...) for this owner's row.
# Intentionally a no-op now.
sub nutrition_estimate_hook { return undef }

1;
