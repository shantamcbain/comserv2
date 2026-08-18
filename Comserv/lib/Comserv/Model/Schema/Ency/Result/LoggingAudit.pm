package Comserv::Model::Schema::Ency::Result::LoggingAudit;
use strict;
use warnings;
use base 'DBIx::Class::Core';

# Logging-coverage audit findings. One row per finding produced by a scan run
# (Comserv::Util::LoggingAudit->run_scan). scan_run_id groups all findings from a
# single scan so the results page can display each run independently. This Result
# class is the SINGLE SOURCE OF TRUTH for the table; deploy the alter through the
# in-app schema-compare workflow — never hand DDL.

__PACKAGE__->table('logging_audit');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'bigint',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    scan_run_id => {
        data_type   => 'varchar',
        size        => 64,
        is_nullable => 0,
    },
    scan_type => {
        # 'log_scan' (system_log grouping) or 'code_scan' (silent-swallow grep)
        data_type   => 'varchar',
        size        => 32,
        is_nullable => 0,
    },
    severity => {
        # 'info' | 'warning' | 'critical'
        data_type   => 'varchar',
        size        => 20,
        is_nullable => 0,
        default_value => 'warning',
    },
    target => {
        # area/source for log_scan, or file path for code_scan
        data_type   => 'varchar',
        size        => 512,
        is_nullable => 1,
    },
    finding => {
        # short finding label (e.g. 'missing_log_with_details', 'error_count')
        data_type   => 'varchar',
        size        => 128,
        is_nullable => 1,
    },
    detail => {
        data_type   => 'text',
        is_nullable => 1,
    },
    file_path => {
        data_type   => 'varchar',
        size        => 512,
        is_nullable => 1,
    },
    line_no => {
        data_type     => 'integer',
        is_nullable   => 1,
    },
    recommendation => {
        data_type   => 'text',
        is_nullable => 1,
    },
    created_at => {
        data_type     => 'datetime',
        is_nullable   => 0,
        default_value => \'CURRENT_TIMESTAMP',
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(
    uniq_scan_run_finding => [qw(scan_run_id scan_type finding target file_path line_no)]
);

1;
