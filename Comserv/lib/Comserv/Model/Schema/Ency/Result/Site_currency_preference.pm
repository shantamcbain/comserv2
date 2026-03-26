package Comserv::Model::Schema::Ency::Result::Site_currency_preference;
use base 'DBIx::Class::Core';

__PACKAGE__->table('site_currency_preference');
__PACKAGE__->add_columns(
    currency_code => {
        data_type => 'char',
        size => 3,
        default_value => 'CAD',
    },
    id => {
        data_type => 'int',
        size => 11,
        is_auto_increment => 1,
    },
    site_id => {
        data_type => 'int',
        size => 11,
    },
    updated_at => {
        data_type => 'timestamp',
        default_value => 'current_timestamp()',
    },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint('uq_scp_site' => ['site_id']);

1;
