package Comserv::Model::Schema::Ency::Result::User;
use base 'DBIx::Class::Core';

__PACKAGE__->table('users');
__PACKAGE__->add_columns(
    id => {
        data_type => 'int',
        is_auto_increment => 1,
    },
    username => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 0,
    },
    password => {
        data_type => 'varchar',
        size => 255,
    },
    first_name => {
        data_type => 'varchar',
        size => 255,
    },
    last_name => {
        data_type => 'varchar',
        size => 255,
    },
    email => {
        data_type => 'varchar',
        size => 255,
    },
    roles => {
        data_type => 'text',
        is_nullable => 1,
        # Enhanced to support both global and site-specific roles
        # Format: "admin,user" or "global:super_admin,site:123:site_admin"
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint('username_unique' => ['username']);

# Relationships
__PACKAGE__->has_many(
    user_site_roles => 'Comserv::Model::Schema::Ency::Result::UserSiteRole',
    'user_id'
);

__PACKAGE__->has_many(
    user_sites => 'Comserv::Model::Schema::Ency::Result::UserSite',
    'user_id'
);

# Mailing List Relationships
__PACKAGE__->has_many(
    mailing_list_subscriptions => 'Comserv::Model::Schema::Ency::Result::MailingListSubscription',
    'user_id'
);

__PACKAGE__->has_many(
    created_mailing_lists => 'Comserv::Model::Schema::Ency::Result::MailingList',
    'created_by'
);

__PACKAGE__->has_many(
    sent_campaigns => 'Comserv::Model::Schema::Ency::Result::MailingListCampaign',
    'sent_by'
);

# Many-to-many relationship with mailing lists through subscriptions
__PACKAGE__->many_to_many(subscribed_mailing_lists => 'mailing_list_subscriptions', 'mailing_list');



1;
