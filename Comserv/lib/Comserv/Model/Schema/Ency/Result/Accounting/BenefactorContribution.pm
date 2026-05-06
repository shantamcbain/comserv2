package Comserv::Model::Schema::Ency::Result::Accounting::BenefactorContribution;
use base 'DBIx::Class::Core';
use warnings FATAL => 'all';

__PACKAGE__->table('benefactor_contributions');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    user_id => {
        data_type      => 'integer',
        is_foreign_key => 1,
        is_nullable    => 0,
        documentation  => 'The benefactor (e.g. Shanta) who made this contribution',
    },
    contribution_type => {
        data_type   => 'enum',
        extra       => { list => [
            'expense_paid',
            'labor_programming',
            'labor_sysadmin',
            'labor_design',
            'labor_support',
            'hardware_donated',
            'other',
        ] },
        is_nullable => 0,
    },
    description => {
        data_type   => 'varchar',
        size        => 500,
        is_nullable => 1,
    },
    amount_cad => {
        data_type     => 'decimal',
        size          => [14, 2],
        default_value => '0.00',
        is_nullable   => 0,
        documentation => 'Dollar value in CAD of this contribution',
    },
    hours => {
        data_type     => 'decimal',
        size          => [8, 2],
        default_value => '0.00',
        is_nullable   => 0,
        documentation => 'Hours of labour contributed (0 for non-labour types)',
    },
    hourly_rate_cad => {
        data_type     => 'decimal',
        size          => [8, 2],
        default_value => '0.00',
        is_nullable   => 0,
        documentation => 'CAD rate used to value labour hours',
    },
    coins_credited => {
        data_type     => 'decimal',
        size          => [14, 4],
        default_value => '0.0000',
        is_nullable   => 0,
        documentation => 'Internal coins credited to benefactor for this contribution',
    },
    currency_transaction_id => {
        data_type      => 'integer',
        is_foreign_key => 1,
        is_nullable    => 1,
        documentation  => 'FK to InternalCurrencyTransaction for this credit',
    },
    cost_tracking_id => {
        data_type      => 'integer',
        is_foreign_key => 1,
        is_nullable    => 1,
        documentation  => 'Optional link to the SystemCostTracking entry this covers',
    },
    contribution_date => {
        data_type   => 'date',
        is_nullable => 0,
    },
    created_at => {
        data_type     => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable   => 0,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    user => 'Comserv::Model::Schema::Ency::Result::User',
    'user_id'
);

__PACKAGE__->belongs_to(
    currency_transaction => 'Comserv::Model::Schema::Ency::Result::Accounting::InternalCurrencyTransaction',
    'currency_transaction_id',
    { join_type => 'left' }
);

__PACKAGE__->belongs_to(
    cost_entry => 'Comserv::Model::Schema::Ency::Result::SystemCostTracking',
    'cost_tracking_id',
    { join_type => 'left' }
);

sub total_value_cad {
    my $self = shift;
    return $self->amount_cad if $self->amount_cad > 0;
    return $self->hours * $self->hourly_rate_cad if $self->hours > 0;
    return 0;
}

1;
