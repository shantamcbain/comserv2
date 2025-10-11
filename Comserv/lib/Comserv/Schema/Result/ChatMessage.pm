package Comserv::Schema::Result::ChatMessage;

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 NAME

Comserv::Schema::Result::ChatMessage

=head1 DESCRIPTION

Schema class for chat messages

=cut

__PACKAGE__->load_components("InflateColumn::DateTime");

__PACKAGE__->table("chat_messages");

__PACKAGE__->add_columns(
    "id",
    { data_type => "integer", is_auto_increment => 1, is_nullable => 0 },
    "username",
    { data_type => "varchar", is_nullable => 0, size => 255 },
    "message",
    { data_type => "text", is_nullable => 0 },
    "timestamp",
    { data_type => "varchar", is_nullable => 0, size => 255 },
    "is_read",
    { data_type => "boolean", is_nullable => 0, default_value => 0 },
    "is_system_message",
    { data_type => "boolean", is_nullable => 1, default_value => 0 },
    "recipient_username",
    { data_type => "varchar", is_nullable => 1, size => 255 },
    "domain",
    { data_type => "varchar", is_nullable => 1, size => 255 },
    "site_name",
    { data_type => "varchar", is_nullable => 1, size => 255 },
);

__PACKAGE__->set_primary_key("id");

1;