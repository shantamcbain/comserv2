package Comserv::Model::Schema::Ency::Result::Accounting::HostingCostConfig;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('hosting_cost_config');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    server_cost_monthly => {
        data_type     => 'decimal',
        size          => [10, 2],
        default_value => '0.00',
        is_nullable   => 0,
    },
    active_site_count => {
        data_type     => 'integer',
        default_value => 1,
        is_nullable   => 0,
    },
    overhead_percent => {
        data_type     => 'decimal',
        size          => [5, 2],
        default_value => '20.00',
        is_nullable   => 0,
    },
    commission_percent => {
        data_type     => 'decimal',
        size          => [5, 2],
        default_value => '10.00',
        is_nullable   => 0,
        documentation => 'One-time commission paid to referring SiteName on first payment',
    },
    member_discount_percent => {
        data_type     => 'decimal',
        size          => [5, 2],
        default_value => '10.00',
        is_nullable   => 0,
        documentation => 'Discount applied if buyer is member of referring SiteName',
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
    updated_by => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    updated_at => {
        data_type     => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP',
        is_nullable   => 0,
    },
);

__PACKAGE__->set_primary_key('id');

sub unit_price {
    my $self = shift;
    return 0 unless $self->active_site_count > 0;
    my $base = $self->server_cost_monthly / $self->active_site_count;
    return sprintf('%.2f', $base * (1 + $self->overhead_percent / 100));
}

1;
