package Comserv::Model::Schema::Ency::Result::MailingListSubscription;
use base 'DBIx::Class::Core';
use strict;
use warnings;

__PACKAGE__->load_components(qw/TimeStamp/);
__PACKAGE__->table('mailing_list_subscriptions');

__PACKAGE__->add_columns(
    id => {
        data_type => 'int',
        size => 11,
        is_nullable => 0,
        is_auto_increment => 1,
    },
    mailing_list_id => {
        data_type => 'int',
        size => 11,
        is_nullable => 0,
    },
    user_id => {
        data_type => 'int',
        size => 11,
        is_nullable => 1,
    },
    email => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    display_name => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    first_name => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    last_name => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    subscription_source => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 1,
        # Values: 'manual', 'workshop', 'auto'
    },
    source_id => {
        data_type => 'int',
        size => 11,
        is_nullable => 1,
    },
    subscribed_at => {
        data_type => 'timestamp',
        is_nullable => 0,
        default_value => 'current_timestamp()',
    },
    is_active => {
        data_type => 'tinyint',
        size => 4,
        is_nullable => 0,
        default_value => '1',
    },
    # status column removed - does not exist in DB table
    # unsubscribed_at => { data_type => 'timestamp', is_nullable => 1 },  # column missing in DB - commented to stop fatal error

    blocked_by => {
        data_type => 'int',
        size => 11,
        is_nullable => 1,
    },
    blocked_at => {
        data_type   => 'timestamp',
        is_nullable => 1,
    },
    blocked_reason => {
        data_type   => 'text',
        is_nullable => 1,
    },
    unsubscribe_token => {
        data_type => 'varchar',
        size      => 64,
        is_nullable => 1,
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