package Comserv::Model::Schema::Ency::Result::Mailing_list_campaigns;
use base 'DBIx::Class::Core';

__PACKAGE__->table('mailing_list_campaigns');
__PACKAGE__->add_columns(
    body_html => {
        data_type => 'text',
        is_nullable => 1,
    },
    body_text => {
        data_type => 'text',
        is_nullable => 1,
    },
    id => {
        data_type => 'int',
        size => 11,
        is_auto_increment => 1,
    },
    mailing_list_id => {
        data_type => 'int',
        size => 11,
    },
    recipient_count => {
        data_type => 'int',
        size => 11,
        default_value => '0',
    },
    role_filter => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    sent_at => {
        data_type => 'timestamp',
        default_value => 'current_timestamp()',
    },
    sent_by => {
        data_type => 'int',
        size => 11,
    },
    source_filter => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    subject => {
        data_type => 'text',
    },
);
__PACKAGE__->set_primary_key('id');

1;
