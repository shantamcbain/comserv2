package Comserv::Model::Schema::Ency::Result::HealthAlert;
use strict;
use warnings;
use base 'DBIx::Class::Core';

# Table: health_alert
# CSC admin must create this table via schema_compare with the following columns:
#   id               int(11) NOT NULL auto_increment PRIMARY KEY
#   first_seen       datetime NOT NULL
#   last_seen        datetime NOT NULL
#   level            varchar(20) NOT NULL          -- CRITICAL / HIGH / MEDIUM / LOW
#   category         varchar(100) NOT NULL         -- DB_ERROR, FILE_UPLOAD, EMAIL, etc.
#   description      text NOT NULL
#   occurrence_count int(11) NOT NULL DEFAULT 1
#   status           varchar(20) NOT NULL DEFAULT 'OPEN'  -- OPEN / ACKNOWLEDGED / RESOLVED
#   system_identifier varchar(255) DEFAULT NULL
#   sitename         varchar(255) DEFAULT NULL
#   resolved_at      datetime DEFAULT NULL
#   notes            text DEFAULT NULL

__PACKAGE__->table('health_alert');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    first_seen => {
        data_type   => 'datetime',
        is_nullable => 0,
    },
    last_seen => {
        data_type   => 'datetime',
        is_nullable => 0,
    },
    level => {
        data_type   => 'varchar',
        size        => 20,
        is_nullable => 0,
    },
    category => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 0,
    },
    description => {
        data_type   => 'text',
        is_nullable => 0,
    },
    occurrence_count => {
        data_type     => 'integer',
        is_nullable   => 0,
        default_value => 1,
    },
    status => {
        data_type     => 'varchar',
        size          => 20,
        is_nullable   => 0,
        default_value => 'OPEN',
    },
    system_identifier => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    sitename => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    resolved_at => {
        data_type   => 'datetime',
        is_nullable => 1,
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');

1;
