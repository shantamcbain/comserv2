package Comserv::Model::Schema::Ency::Result::Accounting::InventoryLocationCount;
use strict;
use warnings;
use base 'DBIx::Class::Core';

# ONE physical count of a consignment placement's container.
#
# Lifecycle (the photo workflow):
#   draft   -- photo uploaded, vision produced raw_text, nothing applied yet
#   applied -- human ticked "text is correct": stock adjusted, consignment
#              settled, draft sales invoice raised, top-up traveller created.
#              The photo file is deleted at this point (image_deleted_at set).
#   void    -- abandoned draft; photo purged by the sweeper.
#
# The TEXT is the record of truth, the image is throw-away evidence.

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('inventory_location_counts');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    sitename => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    placement_id => {
        data_type      => 'integer',
        is_nullable    => 1,
        is_foreign_key => 1,
    },
    location_id => {
        data_type      => 'integer',
        is_nullable    => 0,
        is_foreign_key => 1,
    },
    partner_id => {
        data_type      => 'integer',
        is_nullable    => 1,
        is_foreign_key => 1,
    },
    item_id => {
        data_type      => 'integer',
        is_nullable    => 0,
        is_foreign_key => 1,
    },
    # photo | manual | chat  (chat = counts typed/confirmed in Chat-with-AI)
    source => {
        data_type     => 'varchar',
        size          => 50,
        is_nullable   => 0,
        default_value => 'photo',
    },
    # Transient image file for a draft count. Cleared/deleted on apply.
    image_path => {
        data_type   => 'varchar',
        size        => 500,
        is_nullable => 1,
    },
    image_mime => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    image_deleted_at => {
        data_type   => 'datetime',
        is_nullable => 1,
    },
    # The verified text, e.g. "2 blue, 2 yellow, 1 red, 0 green"
    raw_text => {
        data_type   => 'text',
        is_nullable => 1,
    },
    # Which vision engine produced raw_text (model name), for accuracy tracking
    engine => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    confidence => {
        data_type   => 'decimal',
        size        => [5, 2],
        is_nullable => 1,
    },
    status => {
        data_type     => 'varchar',
        size          => 50,
        is_nullable   => 0,
        default_value => 'draft',
    },
    counted_by => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    counted_at => {
        data_type   => 'datetime',
        is_nullable => 1,
    },
    applied_at => {
        data_type   => 'datetime',
        is_nullable => 1,
    },
    # What the apply step produced (all nullable so a draft touches nothing)
    consignment_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    invoice_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    traveller_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
    created_at => {
        data_type     => 'datetime',
        is_nullable   => 1,
        set_on_create => 1,
    },
    updated_at => {
        data_type     => 'datetime',
        is_nullable   => 1,
        set_on_create => 1,
        set_on_update => 1,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->has_many(
    'lines' => 'Comserv::Model::Schema::Ency::Result::Accounting::InventoryLocationCountLine',
    { 'foreign.count_id' => 'self.id' },
    { cascade_delete => 1 }
);

__PACKAGE__->belongs_to(
    'placement' => 'Comserv::Model::Schema::Ency::Result::Accounting::InventoryConsignmentPlacement',
    { 'foreign.id' => 'self.placement_id' }
);

__PACKAGE__->belongs_to(
    'location' => 'Comserv::Model::Schema::Ency::Result::Accounting::InventoryLocation',
    { 'foreign.id' => 'self.location_id' }
);

__PACKAGE__->belongs_to(
    'partner' => 'Comserv::Model::Schema::Ency::Result::Accounting::InventoryConsignmentPartner',
    { 'foreign.id' => 'self.partner_id' }
);

__PACKAGE__->belongs_to(
    'item' => 'Comserv::Model::Schema::Ency::Result::Accounting::InventoryItem',
    { 'foreign.id' => 'self.item_id' }
);

sub is_draft   { return (($_[0]->status // '') eq 'draft') ? 1 : 0 }
sub is_applied { return (($_[0]->status // '') eq 'applied') ? 1 : 0 }

sub expected_total {
    my ($self) = @_;
    my $t = 0;
    $t += $_->qty_expected + 0 for $self->lines->all;
    return $t;
}

sub counted_total {
    my ($self) = @_;
    my $t = 0;
    $t += $_->qty_counted + 0 for $self->lines->all;
    return $t;
}

# Units that left the location (counted less than expected), per colour.
sub sold_lines {
    my ($self) = @_;
    return grep { ($_->qty_delta // 0) < 0 } $self->lines->all;
}

sub sold_total {
    my ($self) = @_;
    my $t = 0;
    $t += abs($_->qty_delta // 0) for $self->sold_lines;
    return $t;
}

1;
