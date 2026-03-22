package Comserv::Model::Schema::Ency::Result::MailingListSubscription;
use base 'DBIx::Class::Core';
use strict;
use warnings;

__PACKAGE__->load_components(qw/TimeStamp/);
__PACKAGE__->table('mailing_list_subscriptions');

__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    mailing_list_id => {
        data_type => 'integer',
        is_nullable => 0,
    },
    user_id => {
        data_type => 'integer',
        is_nullable => 0,
    },
    subscription_source => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 1,
        # Values: 'manual', 'workshop', 'auto'
    },
    source_id => {
        data_type => 'integer',
        is_nullable => 1,
        # workshop_id if source is 'workshop'
    },
    subscribed_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        set_on_create => 1,
    },
    is_active => {
        data_type => 'tinyint',
        default_value => 1,
    },
);

__PACKAGE__->set_primary_key('id');

# Add unique constraint for mailing_list_id + user_id + source_id combination
__PACKAGE__->add_unique_constraint('unique_subscription' => ['mailing_list_id', 'user_id', 'source_id']);

# Relationships
__PACKAGE__->belongs_to(
    mailing_list => 'Comserv::Model::Schema::Ency::Result::MailingList',
    { 'foreign.id' => 'self.mailing_list_id' },
    { cascade_delete => 1 },
);

__PACKAGE__->belongs_to(
    user => 'Comserv::Model::Schema::Ency::Result::User',
    { 'foreign.id' => 'self.user_id' },
    { cascade_delete => 1 },
);

# Optional relationship to workshop if subscription_source is 'workshop'
__PACKAGE__->belongs_to(
    workshop => 'Comserv::Model::Schema::Ency::Result::WorkShop',
    { 'foreign.id' => 'self.source_id' },
    { join_type => 'left' },
);

1;