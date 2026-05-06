package Comserv::Model::Schema::Ency::Result::Accounting::CurrencyRate;
use base 'DBIx::Class::Core';

__PACKAGE__->table('currency_rates');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'int',
        is_auto_increment => 1,
    },
    currency_code => {
        data_type => 'char',
        size      => 10,
        is_nullable => 0,
    },
    currency_name => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 0,
    },
    rate_to_cad => {
        data_type   => 'decimal',
        size        => [15, 6],
        is_nullable => 0,
    },
    symbol => {
        data_type     => 'varchar',
        size          => 10,
        is_nullable   => 0,
        default_value => '',
    },
    is_active => {
        data_type     => 'tinyint',
        size          => 1,
        is_nullable   => 0,
        default_value => 1,
    },
    source => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    updated_at => {
        data_type     => 'timestamp',
        is_nullable   => 0,
        default_value => \'CURRENT_TIMESTAMP',
    },
    created_at => {
        data_type     => 'timestamp',
        is_nullable   => 0,
        default_value => \'CURRENT_TIMESTAMP',
    },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint('uq_currency_code' => ['currency_code']);

sub points_to_currency {
    my ($self, $points) = @_;
    return $points / $self->rate_to_cad;
}

sub currency_to_points {
    my ($self, $amount) = @_;
    return int($amount * $self->rate_to_cad);
}

1;
