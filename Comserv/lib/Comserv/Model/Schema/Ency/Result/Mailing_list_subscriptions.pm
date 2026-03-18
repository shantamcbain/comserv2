package Comserv::Model::Schema::Ency::Result::Mailing_list_subscriptions;
use base 'DBIx::Class::Core';

__PACKAGE__->table('mailing_list_subscriptions');
__PACKAGE__->add_columns(
    id => {
        data_type => 'int',
        size => 11,
        is_auto_increment => 1,
    },
    is_active => {
        data_type => 'tinyint',
        size => 4,
        default_value => '1',
    },
    mailing_list_id => {
        data_type => 'int',
        size => 11,
    },
    source_id => {
        data_type => 'int',
        size => 11,
        is_nullable => 1,
    },
    subscribed_at => {
        data_type => 'timestamp',
        default_value => 'current_timestamp()',
    },
    subscription_source => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 1,
    },
    user_id => {
        data_type => 'int',
        size => 11,
    },
);
__PACKAGE__->set_primary_key('id');

1;
