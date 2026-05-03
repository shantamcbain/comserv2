package Comserv::Model::Schema::Ency::Result::Beekeeping::Queen;
use base 'DBIx::Class::Core';

__PACKAGE__->table('queens');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    sitename => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 0,
        comment     => 'Site tenant identifier — all queries must filter by this',
    },
    tag_number => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 0,
        comment     => 'Unique identifier / physical tag on the queen',
    },
    birth_date => {
        data_type   => 'date',
        is_nullable => 1,
        comment     => 'Date queen emerged or was estimated to have emerged',
    },
    breed => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
        comment     => 'Breed or race (e.g. Italian, Carniolan, Buckfast)',
    },
    genetic_line => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
        comment     => 'Named breeding line within the breed',
    },
    color_marking => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
        comment     => 'Physical colour dot or paint marking on thorax',
    },
    origin => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
        comment     => 'Source / breeder of the queen',
    },
    parent_queen_id => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'Mother queen — self-referential FK for genetic lineage tracking',
    },
    drone_source => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
        comment     => 'Description or tag of drone source used for mating',
    },
    mating_status => {
        data_type => 'enum',
        extra     => { list => [qw/virgin mated laying drone_layer superseded missing dead/] },
        default_value => 'virgin',
        comment   => 'Current mating and laying lifecycle status',
    },
    laying_status => {
        data_type => 'enum',
        extra     => { list => [qw/laying_well laying_poor not_laying drone_layer superseded missing/] },
        is_nullable => 1,
        comment   => 'Quality of current laying pattern',
    },
    performance_rating => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'Subjective performance score 1-10',
    },
    temperament_rating => {
        data_type => 'enum',
        extra     => { list => [qw/calm moderate aggressive very_aggressive/] },
        default_value => 'calm',
    },
    health_status => {
        data_type => 'enum',
        extra     => { list => [qw/healthy diseased injured missing dead/] },
        default_value => 'healthy',
    },
    location_type => {
        data_type => 'enum',
        extra     => { list => [qw/hive cage unknown/] },
        default_value => 'unknown',
        comment   => 'Queen lives in a hive (all types: full, nuc, mating_nuc — determined by hive BOM) or a cage. Cage location (transport_box, mail, counter) is tracked via the cage inventory_item location.',
    },
    location_notes => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
        comment     => 'Cage tag or cage inventory_item_id reference when location_type=cage',
    },
    purpose => {
        data_type => 'enum',
        extra     => { list => [qw/production breeding replacement sale research/] },
        default_value => 'production',
    },
    introduction_date => {
        data_type   => 'date',
        is_nullable => 1,
        comment     => 'Date queen was introduced to her current hive',
    },
    removal_date => {
        data_type   => 'date',
        is_nullable => 1,
        comment     => 'Date queen was removed, superseded, or died',
    },
    inventory_item_id => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'FK → inventory_items — queen as inventory item (tracks cost, purchase_date, supplier, stock)',
    },
    status => {
        data_type => 'enum',
        extra     => { list => [qw/active inactive sold dead missing/] },
        default_value => 'active',
    },
    comments => {
        data_type   => 'text',
        is_nullable => 1,
        comment     => 'General notes (kept for backward compatibility)',
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
        comment     => 'Detailed notes on this queen',
    },
    created_at => {
        data_type     => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
    },
    updated_at => {
        data_type     => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP',
    },
    created_by => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
    },
    updated_by => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->add_unique_constraint(
    tag_number_sitename_unique => ['tag_number', 'sitename'],
);

# --- Relationships --------------------------------------------------------

__PACKAGE__->belongs_to(
    'parent_queen',
    'Comserv::Model::Schema::Ency::Result::Queen',
    'parent_queen_id',
    { is_deferrable => 1, on_delete => 'SET NULL', join_type => 'LEFT' }
);

__PACKAGE__->has_many(
    'offspring_queens',
    'Comserv::Model::Schema::Ency::Result::Queen',
    'parent_queen_id',
    { cascade_delete => 0 }
);

__PACKAGE__->belongs_to(
    'inventory_item',
    'Comserv::Model::Schema::Ency::Result::Accounting::InventoryItem',
    { 'foreign.id' => 'self.inventory_item_id' },
    { is_deferrable => 1, on_delete => 'SET NULL', join_type => 'LEFT' }
);

__PACKAGE__->has_many(
    'queen_events',
    'Comserv::Model::Schema::Ency::Result::Beekeeping::QueenEvent',
    'queen_id',
    { cascade_delete => 1 }
);

__PACKAGE__->has_many(
    'queen_hive_assignments',
    'Comserv::Model::Schema::Ency::Result::Beekeeping::QueenHiveAssignment',
    'queen_id',
    { cascade_delete => 1 }
);

__PACKAGE__->has_many(
    'inspections',
    'Comserv::Model::Schema::Ency::Result::Beekeeping::Inspection',
    'queen_id',
    { cascade_delete => 0 }
);

# --- Custom methods -------------------------------------------------------

sub display_name {
    my $self = shift;
    my $name = $self->tag_number;
    $name .= " (" . $self->genetic_line . ")" if $self->genetic_line;
    return $name;
}

sub current_location {
    my $self = shift;
    my $lt = $self->location_type // 'unknown';

    if ( $lt eq 'hive' ) {
        my $hive = $self->current_hive;
        if ( $hive ) {
            my $label = 'Hive: ' . $hive->hive_number;
            my $yard  = $hive->yard;
            $label .= ' @ ' . $yard->name if $yard;
            return $label;
        }
        return 'Hive: unknown (no active assignment)';
    }

    if ( $lt eq 'cage' ) {
        return 'Cage' . ( $self->location_notes ? ': ' . $self->location_notes : '' );
    }

    return 'Unknown location';
}

sub is_in_transit {
    my $self = shift;
    return ( $self->location_type // '' ) eq 'cage';
}

sub is_placed {
    my $self = shift;
    return ( $self->location_type // '' ) eq 'hive';
}

sub current_hive {
    my $self = shift;
    my $assignment = $self->queen_hive_assignments->search(
        { removed_date => undef },
        { order_by => { -desc => 'assigned_date' }, rows => 1 }
    )->first;
    return $assignment ? $assignment->hive : undef;
}

sub age_in_days {
    my $self = shift;
    return unless $self->birth_date;
    my $birth_str = $self->birth_date;
    my ($y, $m, $d) = split /-/, $birth_str;
    use POSIX qw(mktime);
    my $birth_epoch = mktime(0, 0, 0, $d, $m - 1, $y - 1900);
    return int( (time - $birth_epoch) / 86400 );
}

sub is_productive {
    my $self = shift;
    return $self->laying_status && $self->laying_status eq 'laying_well';
}

sub needs_attention {
    my $self = shift;
    return $self->health_status ne 'healthy'
        || ( $self->laying_status && $self->laying_status =~ /^(not_laying|drone_layer|superseded)$/ )
        || $self->mating_status eq 'missing';
}

sub calculate_performance_score {
    my $self = shift;
    my $score = ( $self->performance_rating || 5 ) * 10;

    if ( $self->laying_status ) {
        $score += 20 if $self->laying_status eq 'laying_well';
        $score += 10 if $self->laying_status eq 'laying_poor';
        $score -= 30 if $self->laying_status eq 'not_laying';
        $score -= 50 if $self->laying_status eq 'drone_layer';
    }
    if ( $self->temperament_rating ) {
        $score += 10 if $self->temperament_rating eq 'calm';
        $score -= 10 if $self->temperament_rating eq 'aggressive';
        $score -= 20 if $self->temperament_rating eq 'very_aggressive';
    }
    $score -= 20 if $self->health_status ne 'healthy';

    my $age = $self->age_in_days;
    if ($age) {
        $score += 10 if $age > 365 && $age < 730;
        $score -= 15 if $age > 1095;
    }

    return $score > 100 ? 100 : ( $score < 0 ? 0 : $score );
}

1;

=head1 NAME

Comserv::Model::Schema::Ency::Result::Queen - Canonical queen record (queens table)

=head1 DESCRIPTION

Canonical queen tracking table. Replaces and extends the minimal original schema
with full lifecycle management: genetic lineage, performance scoring, location
tracking, event history, and hive assignment history.

Architecture: Queen IS an InventoryItem (same pattern as Box.pm, HiveFrame.pm).
The inventory_item_id FK links to inventory_items for acquisition cost,
purchase date, supplier, and marketable stock management.

INVENTORY CREATION RULE:
  - Home-reared queen: inventory_item_id is NULL while cell/virgin.
    Controller creates the inventory_item record at mating confirmation
    (mating_status transitions to 'mated'). SKU = "Q-{sitename}-{tag_number}".
  - Purchased queen: inventory_item created first (at purchase/order).
    Queen record created linked to that item. Queen enters at 'mated' or 'laying'.

LOCATION MODEL:
  A queen lives in exactly one of two places:
  - hive  → current_hive_configuration_id identifies the hive configuration.
             Hive type (full, nuc, mating_nuc, single, double) is defined by the hive BOM,
             not by the queen record. All hive variants map to location_type='hive'.
  - cage  → queen is in an introduction or transit cage.
             The cage itself is an inventory_item with its own location (transport_box,
             kitchen counter, mail, etc.) tracked via the inventory location system.
             location_notes holds the cage tag or cage inventory_item reference.
  queen_hive_assignments records the full history of hive placements.

Schema changes from the original queens table (applied via /admin/schema_comparison):
- Added: genetic_line, color_marking, parent_queen_id (self-ref FK), drone_source
- Changed: mating_status varchar → ENUM; health_status varchar → ENUM
- Added: laying_status ENUM, temperament_rating ENUM, purpose ENUM, status ENUM
- Added: current_yard_id FK, current_pallet_id FK, current_position,
         current_hive_configuration_id FK
- Added: inventory_item_id FK → inventory_items (replaces acquisition_cost/date)
- Added: notes, created_at, updated_at, created_by, updated_by
- Kept:  comments (backward compat), introduction_date, removal_date,
         breed, origin, performance_rating, tag_number, birth_date
- Removed: acquisition_cost, acquisition_date — use inventory_item.unit_cost
           and inventory_item.purchase_date instead

=head1 RELATIONSHIPS

=over 4

=item * inventory_item — queen as inventory item (cost, purchase_date, supplier via InventoryItem.pm)

=item * parent_queen / offspring_queens — genetic family tree (self-ref)

=item * current_yard / current_pallet / current_hive_configuration — denormalised location

=item * queen_events — lifecycle event log (QueenEvent.pm)

=item * queen_hive_assignments — full hive assignment history (QueenHiveAssignment.pm)

=item * inspections — hive inspections where this queen was noted (via queen_id FK on inspections)

=back

=head1 SEE ALSO

L<Comserv::Model::Schema::Ency::Result::Beekeeping::QueenEvent>,
L<Comserv::Model::Schema::Ency::Result::Beekeeping::QueenHiveAssignment>,
L<Comserv::Model::Schema::Ency::Result::Beekeeping::QueenEnhanced>

=cut
