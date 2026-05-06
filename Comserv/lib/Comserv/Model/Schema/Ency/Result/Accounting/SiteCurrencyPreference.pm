package Comserv::Model::Schema::Ency::Result::Accounting::SiteCurrencyPreference;
use base 'DBIx::Class::Core';

__PACKAGE__->table('site_currency_preference');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'int',
        is_auto_increment => 1,
    },
    site_id => {
        data_type   => 'int',
        is_nullable => 0,
    },
    currency_code => {
        data_type     => 'char',
        size          => 10,
        is_nullable   => 0,
        default_value => 'CAD',
    },
    updated_at => {
        data_type     => 'timestamp',
        is_nullable   => 0,
        default_value => \'CURRENT_TIMESTAMP',
    },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint('uq_site_currency' => ['site_id']);

__PACKAGE__->belongs_to(
    site => 'Comserv::Model::Schema::Ency::Result::Site',
    'site_id',
);

__PACKAGE__->belongs_to(
    currency => 'Comserv::Model::Schema::Ency::Result::Accounting::CurrencyRate',
    'currency_code',
    { fk_columns => { currency_code => 'currency_code' } },
);

1;
