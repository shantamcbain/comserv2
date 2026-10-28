package Comserv::Model::Schema::Ency::Result::SystemLog;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('system_log');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    timestamp => {
        data_type   => 'datetime',
        is_nullable => 0,
    },
    level => {
        data_type   => 'varchar',
        size        => 20,
        is_nullable => 0,
    },
    file => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    line => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    subroutine => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    message => {
        data_type   => 'text',
        is_nullable => 0,
    },
    sitename => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    username => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    system_identifier => {
        data_type      => 'varchar',
        size           => 255,
        is_nullable    => 1,
        default_value  => undef,
    },
    occurrence_count => {
        data_type     => 'bigint',
        is_nullable   => 0,
        default_value => 1,
    },
    first_seen => {
        data_type   => 'datetime',
        is_nullable => 1,
    },
    last_seen => {
        data_type   => 'datetime',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');

# Index for Util::LoginThrottle (and any "recent rows of one subroutine" query):
# WHERE subroutine = 'login_throttle' AND timestamp >= ?  and the hourly prune.
# This DBIx::Class build has no add_index, so it is declared the DBIC way, through
# sqlt_deploy_hook (used by $schema->deploy / deployment_statements). Schema Compare
# only compares columns and unique constraints, so it does NOT create this index
# on an existing table - see the note that came with this change.
sub sqlt_deploy_hook {
    my ($self, $sqlt_table) = @_;
    $sqlt_table->add_index(
        name   => 'idx_system_log_subroutine_timestamp',
        fields => [qw(subroutine timestamp)],
    );
}

1;
