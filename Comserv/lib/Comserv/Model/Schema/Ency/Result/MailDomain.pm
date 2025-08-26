package Comserv::Model::Schema::Ency::Result::MailDomain;
use base 'DBIx::Class::Core';
use strict;
use warnings;

__PACKAGE__->load_components(qw/TimeStamp/);
__PACKAGE__->table('mail_domains');
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    domain_id => {
        data_type => 'integer',
    },
    dkim_selector => {
        data_type => 'varchar',
        size => 255,
        default_value => 'mail',
    },
    dkim_public_key => {
        data_type => 'text',
        is_nullable => 1,
    },
    spf_record => {
        data_type => 'text',
        is_nullable => 1,
    },
    mx_records => {
        data_type => 'json',
        is_nullable => 1,
    },
    dmarc_record => {
        data_type => 'text',
        is_nullable => 1,
    },
    status => {
        data_type => 'enum',
        extra => { list => [qw/pending active error/] },
        default_value => 'pending',
    },
    error_message => {
        data_type => 'text',
        is_nullable => 1,
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
__PACKAGE__->belongs_to(
    domain => 'Comserv::Model::Schema::Ency::Result::SiteDomain',
    'domain_id'
);

1;