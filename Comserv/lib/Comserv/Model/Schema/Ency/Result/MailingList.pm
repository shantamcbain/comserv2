package Comserv::Model::Schema::Ency::Result::MailingList;
use base 'DBIx::Class::Core';
use strict;
use warnings;

__PACKAGE__->load_components(qw/TimeStamp/);
__PACKAGE__->table('mailing_lists');

__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    site_id => {
        data_type => 'integer',
        is_nullable => 0,
    },
    name => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 0,
    },
    description => {
        data_type => 'text',
        is_nullable => 1,
    },
    list_email => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    virtualmin_list_id => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    is_software_only => {
        data_type => 'tinyint',
        default_value => 1,
    },
    is_active => {
        data_type => 'tinyint',
        default_value => 1,
    },
    created_by => {
        data_type => 'integer',
        is_nullable => 0,
    },
    created_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        set_on_create => 1,
    },
    updated_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP',
        set_on_create => 1,
        set_on_update => 1,
    },
);

__PACKAGE__->set_primary_key('id');

# Add unique constraint for site_id + name combination
__PACKAGE__->add_unique_constraint('unique_site_name' => ['site_id', 'name']);

# Relationships
__PACKAGE__->belongs_to(
    site => 'Comserv::Model::Schema::Ency::Result::Site',
    { 'foreign.id' => 'self.site_id' },
);

__PACKAGE__->belongs_to(
    creator => 'Comserv::Model::Schema::Ency::Result::User',
    { 'foreign.id' => 'self.created_by' },
);

__PACKAGE__->has_many(
    subscriptions => 'Comserv::Model::Schema::Ency::Result::MailingListSubscription',
    'mailing_list_id'
);

__PACKAGE__->has_many(
    campaigns => 'Comserv::Model::Schema::Ency::Result::MailingListCampaign',
    'mailing_list_id'
);

# Many-to-many relationship with users through subscriptions
__PACKAGE__->many_to_many(subscribers => 'subscriptions', 'user');

1;