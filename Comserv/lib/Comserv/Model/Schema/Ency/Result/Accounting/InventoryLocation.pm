package Comserv::Model::Schema::Ency::Result::Accounting::InventoryLocation;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('inventory_locations');

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
    name => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    description => {
        data_type   => 'text',
        is_nullable => 1,
    },
    location_type => {
        data_type     => 'varchar',
        size          => 100,
        is_nullable   => 1,
        default_value => 'warehouse',
    },
    address => {
        data_type   => 'text',
        is_nullable => 1,
    },
    status => {
        data_type     => 'varchar',
        size          => 50,
        is_nullable   => 0,
        default_value => 'active',
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
    is_storage_box => {
        data_type     => 'integer',
        size          => 1,
        is_nullable   => 0,
        default_value => '0',
    },
    parent_location_id => {
        data_type   => 'integer',
        size        => 11,
        is_nullable => 1,
    },
    box_type => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
    },
    box_dimensions => {
        data_type   => 'text',
        is_nullable => 1,
    },
    box_capacity => {
        data_type   => 'integer',
        size        => 11,
        is_nullable => 1,
    },
    image_url => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    last_scan_date => {
        data_type   => 'datetime',
        is_nullable => 1,
    },
    contents_description => {
        data_type   => 'text',
        is_nullable => 1,
    },
    scan_accuracy => {
        data_type   => 'integer',
        size        => 3,
        is_nullable => 1,
    },
    created_by => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    created_at => {
        data_type   => 'datetime',
        is_nullable => 1,
        set_on_create => 1,
    },
    updated_at => {
        data_type   => 'datetime',
        is_nullable => 1,
        set_on_create => 1,
        set_on_update => 1,
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint('sitename_name_unique', ['sitename', 'name']);
__PACKAGE__->add_unique_constraint('idx_parent_location_id', ['parent_location_id']);
__PACKAGE__->add_unique_constraint('idx_is_storage_box', ['is_storage_box']);

__PACKAGE__->has_many(
    'stock_levels' => 'Comserv::Model::Schema::Ency::Result::Accounting::InventoryStockLevel',
    { 'foreign.location_id' => 'self.id' },
    { cascade_delete => 0 }
);

__PACKAGE__->has_many(
    'assignments' => 'Comserv::Model::Schema::Ency::Result::Accounting::InventoryAssignment',
    { 'foreign.location_id' => 'self.id' },
    { cascade_delete => 0 }
);

__PACKAGE__->has_many(
    'child_boxes' => 'Comserv::Model::Schema::Ency::Result::Accounting::InventoryLocation',
    { 'foreign.parent_location_id' => 'self.id' },
    { cascade_delete => 0 }
);

# Custom methods for storage box operations
sub is_storage_box {
    my ($self) = @_;
    return $self->is_storage_box;
}

sub get_parent_location {
    my ($self) = @_;
    return $self->_schema->resultset('Accounting::InventoryLocation')->find($self->parent_location_id) if $self->parent_location_id;
}

sub get_child_boxes {
    my ($self) = @_;
    return $self->child_boxes;
}

sub set_parent_location {
    my ($self, $parent_id) = @_;
    $self->parent_location_id($parent_id);
    return $self;
}

sub get_box_hierarchy {
    my ($self) = @_;
    my $hierarchy = {};
    $hierarchy->{location} = $self;
    $hierarchy->{parent} = $self->get_parent_location;
    $hierarchy->{children} = $self->get_child_boxes;
    return $hierarchy;
}

sub get_box_analysis {
    my ($self) = @_;
    return {
        contents_description => $self->contents_description,
        scan_accuracy        => $self->scan_accuracy,
        last_scan_date       => $self->last_scan_date,
        image_url            => $self->image_url,
        is_storage_box       => $self->is_storage_box,
    };
}

1;

