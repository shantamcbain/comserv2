package Comserv::Model::Schema::Ency::Result::MailingListCampaign;
use base 'DBIx::Class::Core';
use strict;
use warnings;

__PACKAGE__->load_components(qw/TimeStamp/);
__PACKAGE__->table('mailing_list_campaigns');

__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    mailing_list_id => {
        data_type => 'integer',
        is_nullable => 0,
    },
    subject => {
        data_type => 'varchar',
        size => 500,
        is_nullable => 0,
    },
    body_text => {
        data_type => 'text',
        is_nullable => 1,
    },
    body_html => {
        data_type => 'text',
        is_nullable => 1,
    },
    sent_by => {
        data_type => 'integer',
        is_nullable => 0,
    },
    sent_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        set_on_create => 1,
    },
    recipient_count => {
        data_type => 'integer',
        default_value => 0,
    },
    role_filter => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
        # JSON array of roles to filter by
    },
    source_filter => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
        # JSON array of sources to filter by
    },
);

__PACKAGE__->set_primary_key('id');

# Relationships
__PACKAGE__->belongs_to(
    mailing_list => 'Comserv::Model::Schema::Ency::Result::MailingList',
    { 'foreign.id' => 'self.mailing_list_id' },
);

__PACKAGE__->belongs_to(
    sender => 'Comserv::Model::Schema::Ency::Result::User',
    { 'foreign.id' => 'self.sent_by' },
);

1;