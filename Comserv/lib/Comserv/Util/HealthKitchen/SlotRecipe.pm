package Comserv::Util::HealthKitchen::SlotRecipe;

# Links Health Kitchen day-slot todos (comments carry hk_day_slot:<slot>)
# to real recipes, so the calendar card shows the recipe name + ingredients
# and Done can offer an in-place "Mark made" (recipe_make / consume_recipe).
#
#   hk_recipe:<id> in comments -> fixed recipe for that slot (e.g. First drink)
#   otherwise the user's meal plan entry for that date + mapped meal_slot.
# Read-only: nothing here writes. Titles/ingredients are derived for display.
# Every recipe lookup is scoped to the current owner (username_of_poster) AND
# site, the same policy consume_recipe uses; a forged/cross-owner/cross-site
# hk_recipe tag yields no card. Todos without hk_day_slot / hk_recipe are ignored.

use strict;
use warnings;

# day slot -> hk_meal_plan_entry.meal_slot
our %SLOT_MEAL = (
    breakfast  => 'breakfast',
    plate_1000 => 'lunch',
    plate_1700 => 'dinner',
);

# Slots whose recipe is the same every day (resolved by name, owner+site scoped).
our %FIXED_SLOT_RECIPE_NAME = ( first_drink => 'Morning beverage' );

sub parse_recipe_tag {
    my ( $class, $comments ) = @_;
    return undef unless defined $comments;
    return $comments =~ /(?:^|[\s|])hk_recipe:(\d+)\b/ ? $1 + 0 : undef;
}

sub parse_slot {
    my ( $class, $comments ) = @_;
    return undef unless defined $comments;
    return $comments =~ /hk_day_slot:([a-z0-9_]+)/ ? $1 : undef;
}

sub line_text {
    my ( $class, $l ) = @_;
    my $q = $l->{quantity_text};
    unless ( defined $q && length $q ) {
        $q = defined $l->{quantity} ? $l->{quantity} + 0 : '';
        $q .= ' ' . $l->{unit} if length $q && defined $l->{unit} && length $l->{unit};
    }
    my $t = join ' ', grep { defined && length } $q, $l->{name_raw};
    $t .= ' (optional)' if $l->{is_optional};
    return $t;
}

# $owner = { username => ..., sitename => ... }; both required (fail closed).
sub _owner_ok {
    my ( $class, $owner ) = @_;
    return ref $owner eq 'HASH'
        && defined $owner->{username} && length $owner->{username}
        && defined $owner->{sitename} && length $owner->{sitename};
}

sub _owner_cond {
    my ( $class, $owner ) = @_;
    return ( 'me.sitename' => $owner->{sitename}, 'me.username_of_poster' => $owner->{username} );
}

sub recipe_card {
    my ( $class, $schema, $id, $owner ) = @_;
    return undef unless $id && $id =~ /^\d+$/ && $class->_owner_ok($owner);
    my $r = eval {
        $schema->resultset('Recipe')->search(
            { 'me.id' => $id, $class->_owner_cond($owner) },
            { prefetch => 'lines' } )->next;    # single() can't collapse has_many
    };
    return undef unless $r;
    my @lines = sort { ( $a->sort_order // 0 ) <=> ( $b->sort_order // 0 ) } $r->lines->all;
    return {
        id          => $r->id + 0,
        name        => $r->name,
        ingredients => [ map { $class->line_text( { $_->get_columns } ) } @lines ],
        url         => '/healthkitchen/recipes#recipe-' . $r->id,
    };
}

sub _plan_recipe_ids {
    my ( $class, $schema, $user_id, $date, $meal_slot ) = @_;
    my @ids = eval {
        map { $_->recipe_id } $schema->resultset('HealthKitchen::MealPlanEntry')->search(
            {   'me.plan_date'        => $date,
                'me.meal_slot'        => $meal_slot,
                'me.recipe_id'        => { '!=' => undef },
                'meal_plan.user_id'   => $user_id,
                'meal_plan.status'    => { '!=' => 'archived' },
            },
            { join => 'meal_plan', order_by => [ { -desc => 'meal_plan.id' }, 'me.id' ] }
        )->all;
    };
    return @ids;
}

# Returns { todo_id => card } for the given todos on $date.
# Only the owner's own todos (user_id == $user_id) get cards.
sub cards_for_todos {
    my ( $class, $schema, $todos, $date, $user_id, $owner ) = @_;
    my %out;
    return \%out unless $user_id && $class->_owner_ok($owner);
    $todos = [ grep { ( eval { $_->user_id } // '' ) eq $user_id } @$todos ];
    my %fixed_ids;
    my %rid_for;
    for my $t (@$todos) {
        my $cm  = eval { $t->comments } // '';
        my $id  = $class->parse_recipe_tag($cm);
        if ( !$id ) {
            my $slot = $class->parse_slot($cm);
            my $r = $slot ? $class->_fixed_recipe( $schema, $slot, $owner ) : undef;
            $id = $r->id if $r;
        }
        next unless $id;
        $rid_for{ $t->record_id } = $id;
        $fixed_ids{$id} = 1;
    }
    for my $t (@$todos) {
        my $cm   = eval { $t->comments } // '';
        my $rid  = $rid_for{ $t->record_id };
        my $slot = $class->parse_slot($cm);
        if ( !$rid && $slot && $SLOT_MEAL{$slot} && $user_id && $date ) {
            ($rid) = grep { !$fixed_ids{$_} }
                $class->_plan_recipe_ids( $schema, $user_id, $date, $SLOT_MEAL{$slot} );
        }
        next unless $rid;
        my $card = $class->recipe_card( $schema, $rid, $owner ) or next;
        $out{ $t->record_id } = $card;
    }
    return \%out;
}

sub _fixed_recipe {
    my ( $class, $schema, $slot, $owner ) = @_;
    my $name = $FIXED_SLOT_RECIPE_NAME{ $slot // '' } or return undef;
    return undef unless $class->_owner_ok($owner);
    return eval {
        $schema->resultset('Recipe')->search(
            { 'me.name' => $name, $class->_owner_cond($owner) },
            { order_by => 'me.id', rows => 1 } )->single;
    };
}

1;
