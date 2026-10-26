package Comserv::Model::Schema::Ency::Result::UserMailbox;
use base 'DBIx::Class::Core';
use strict;
use warnings;

# Existing mailbox a user connected for invoice mail. Password is stored ONLY
# as Comserv::Util::Encryption ciphertext (namespace 'mail'); never plaintext.
# Create the table via schema-compare. Do not hand-write DDL.
__PACKAGE__->table('user_mailboxes');
__PACKAGE__->add_columns(
    id            => { data_type => 'integer', is_auto_increment => 1, is_nullable => 0 },
    user_id       => { data_type => 'integer', is_nullable => 1 },
    sitename      => { data_type => 'varchar', size => 100, is_nullable => 0, default_value => '' },
    site_managed  => { data_type => 'tinyint', is_nullable => 0, default_value => 0 },
    email_address => { data_type => 'varchar', size => 255, is_nullable => 0 },
    login_username=> { data_type => 'varchar', size => 255, is_nullable => 0 },
    password_enc  => { data_type => 'text',    is_nullable => 1 },
    imap_host     => { data_type => 'varchar', size => 255, is_nullable => 0, default_value => '' },
    imap_port     => { data_type => 'integer', is_nullable => 0, default_value => 993 },
    imap_security => { data_type => 'varchar', size => 10,  is_nullable => 0, default_value => 'ssl' },
    # Comma-separated IMAP folders to read (e.g. "INBOX, INBOX/coop"). NULL/blank = INBOX.
    imap_folders  => { data_type => 'varchar', size => 500, is_nullable => 1 },
    smtp_host     => { data_type => 'varchar', size => 255, is_nullable => 0, default_value => '' },
    smtp_port     => { data_type => 'integer', is_nullable => 0, default_value => 465 },
    smtp_security => { data_type => 'varchar', size => 10,  is_nullable => 0, default_value => 'ssl' },
    pop_host      => { data_type => 'varchar', size => 255, is_nullable => 1 },
    pop_port      => { data_type => 'integer', is_nullable => 1, default_value => 995 },
    last_test_ok  => { data_type => 'tinyint', is_nullable => 1 },
    last_test_at  => { data_type => 'datetime', is_nullable => 1 },
    last_test_msg => { data_type => 'varchar', size => 500, is_nullable => 1 },
    created_at    => { data_type => 'datetime', is_nullable => 1 },
    updated_at    => { data_type => 'datetime', is_nullable => 1 },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(user_mailboxes_email_site => [qw(email_address sitename)]);

1;
