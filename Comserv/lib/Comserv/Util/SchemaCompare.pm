# AI-REMINDER: keep file < 1 500 lines; follow .ai-policy.md
package Comserv::Util::SchemaCompare;
use Moose;
use namespace::autoclean;
use Try::Tiny;
use Data::Dumper;

# Use the split focused modules (keeps this facade tiny)
use Comserv::Util::Schema::ResultParser;
use Comserv::Util::Schema::Inspector;

=head1 NAME

Comserv::Util::SchemaCompare - Database vs Result file comparison utilities

=cut

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

sub compare_table {
    my ($self, $c, $table_name, $database, $result_table_mapping) = @_;

    my $comparison = {
        table_name         => $table_name,
        database           => $database,
        has_result_file    => 0,
        result_file_path   => undef,
        database_schema    => {},
        result_file_schema => {},
        differences        => [],
        sync_status        => 'unknown',
        last_modified      => undef,
    };

    my $table_key = lc($table_name);
    return $comparison unless exists $result_table_mapping->{$table_key};

    my $result_info = $result_table_mapping->{$table_key};
    $comparison->{has_result_file}    = 1;
    $comparison->{result_file_path}   = $result_info->{result_path};
    $comparison->{last_modified}      = $result_info->{last_modified};

    try {
        if ($database eq 'ency') {
            $comparison->{database_schema} = $self->get_ency_table_schema($c, $table_name);
        } elsif ($database eq 'forager') {
            $comparison->{database_schema} = $self->get_forager_table_schema($c, $table_name);
        }
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'compare_table',
            "Error getting database schema for $table_name: $_");
    };

    try {
        $comparison->{result_file_schema} = $self->parse_result_file_schema($c, $result_info->{result_path});
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'compare_table',
            "Error parsing Result file schema for $table_name: $_");
    };

    $comparison->{differences} = $self->find_schema_differences(
        $comparison->{database_schema},
        $comparison->{result_file_schema}
    );

    # Ensure Result-only columns are surfaced
    my %db_cols  = map { $_ => 1 } keys %{ $comparison->{database_schema}{columns} || {} };
    my %res_cols = %{ $comparison->{result_file_schema}{columns} || {} };
    foreach my $col (keys %res_cols) {
        unless (exists $db_cols{$col}) {
            push @{ $comparison->{differences} }, {
                type             => 'missing_in_database',
                column           => $col,
                description      => "Column '$col' exists in Result file but not in database",
                result_definition => $res_cols{$col},
            };
        }
    }

    # Build fields structure for template (Result-only columns must be included)
    $comparison->{fields} = {};
    my %all_fields = ();
    if ($comparison->{database_schema}{columns}) {
        %all_fields = (%all_fields, map { $_ => 1 } keys %{$comparison->{database_schema}{columns}});
    }
    if ($comparison->{result_file_schema}{columns}) {
        %all_fields = (%all_fields, map { $_ => 1 } keys %{$comparison->{result_file_schema}{columns}});
    }
    foreach my $field_name (sort keys %all_fields) {
        $comparison->{fields}{$field_name} = {
            table  => $comparison->{database_schema}{columns}{$field_name},
            result => $comparison->{result_file_schema}{columns}{$field_name},
        };
    }

    # Safety net: ensure any Result-only columns found via differences are present in fields
    # so the UI can always display them for "add field to table" actions.
    if ($comparison->{differences}) {
        foreach my $d (@{ $comparison->{differences} }) {
            if (($d->{type} || '') eq 'missing_in_database' && $d->{column}) {
                my $fn = $d->{column};
                $comparison->{fields}{$fn} ||= { table => undef, result => undef };
                if ($d->{result_definition}) {
                    $comparison->{fields}{$fn}{result} ||= $d->{result_definition};
                } elsif ($comparison->{result_file_schema}{columns}{$fn}) {
                    $comparison->{fields}{$fn}{result} ||= $comparison->{result_file_schema}{columns}{$fn};
                }
            }
        }
    }

    $comparison->{sync_status} = scalar(@{ $comparison->{differences} }) ? 'needs_sync' : 'synchronized';
    return $comparison;
}

# --- Delegated methods (will be moved in future micro-steps) ---
sub get_ency_table_schema    { shift; Comserv::Controller::Admin->get_ency_table_schema(@_) }
sub get_forager_table_schema { shift; Comserv::Controller::Admin->get_forager_table_schema(@_) }
sub parse_result_file_schema {
    my ($self, $file_path) = @_;
    return Comserv::Util::Schema::ResultParser->new->get_result_file_schema($file_path);
}

# Unified high-level entry used by all display paths (local + mig) to guarantee same groups code
sub get_comparison_for_tables {
    my ($self, $c, $database_label, $table_names, $opts) = @_;
    $opts ||= {};

    # Prefer the existing consolidated builder (in Admin for now, will be fully extracted)
    if ($c && $c->can('controller') && $c->controller('Admin')) {
        my $admin = $c->controller('Admin');
        if ($admin->can('build_schema_comparison_data')) {
            return $admin->build_schema_comparison_data($c, $database_label, $table_names);
        }
    }

    # Fallback using new modules + old compare
    my $parser = Comserv::Util::Schema::ResultParser->new;
    my $mapping = $parser->build_result_table_mapping($database_label, $c);

    my @comparisons = ();
    foreach my $tname (@$table_names) {
        my $comp = $self->compare_table($c, $tname, $database_label, $mapping);
        push @comparisons, $comp;
    }

    my @orphans = $self->find_orphaned_result_files_v2($c, $database_label, $table_names, $mapping);

    return {
        table_comparisons => \@comparisons,
        results_without_tables => \@orphans,
        tables_with_results_count => scalar(grep { $_->{has_result_file} } @comparisons),
        tables_without_results_count => scalar(grep { !$_->{has_result_file} } @comparisons),
        results_without_tables_count => scalar(@orphans),
    };
}

# Moved method (first real extraction)
sub find_schema_differences {
    my ($self, $db_schema, $result_schema) = @_;

    my @differences = ();

    my %db_columns = %{$db_schema->{columns} || {}};
    my %result_columns = %{$result_schema->{columns} || {}};

    # Find columns in database but not in Result file
    foreach my $col_name (keys %db_columns) {
        unless (exists $result_columns{$col_name}) {
            push @differences, {
                type => 'missing_in_result',
                column => $col_name,
                description => "Column '$col_name' exists in database but not in Result file"
            };
        }
    }

    # Find columns in Result file but not in database -- include def so UI can add it to table
    foreach my $col_name (keys %result_columns) {
        unless (exists $db_columns{$col_name}) {
            push @differences, {
                type => 'missing_in_database',
                column => $col_name,
                description => "Column '$col_name' exists in Result file but not in database",
                result_definition => $result_columns{$col_name}
            };
        }
    }

    # Compare column attributes for common columns
    foreach my $col_name (keys %db_columns) {
        if (exists $result_columns{$col_name}) {
            my $db_col = $db_columns{$col_name};
            my $result_col = $result_columns{$col_name};

            if (($db_col->{data_type} || '') ne ($result_col->{data_type} || '')) {
                push @differences, {
                    type => 'column_type_mismatch',
                    column => $col_name,
                    database_value => $db_col->{data_type},
                    result_value => $result_col->{data_type},
                    description => "Data type mismatch for column '$col_name'"
                };
            }

            if (($db_col->{is_nullable} || 0) != ($result_col->{is_nullable} || 0)) {
                push @differences, {
                    type => 'column_nullable_mismatch',
                    column => $col_name,
                    database_value => $db_col->{is_nullable} ? 'YES' : 'NO',
                    result_value => $result_col->{is_nullable} ? 'YES' : 'NO',
                    description => "Nullable status mismatch for column '$col_name'"
                };
            }

            if (($db_col->{size} || '') ne ($result_col->{size} || '')) {
                push @differences, {
                    type => 'column_size_mismatch',
                    column => $col_name,
                    database_value => $db_col->{size} || 'N/A',
                    result_value => $result_col->{size} || 'N/A',
                    description => "Size mismatch for column '$col_name'"
                };
            }

            if (($db_col->{is_auto_increment} || 0) != ($result_col->{is_auto_increment} || 0)) {
                push @differences, {
                    type => 'column_auto_increment_mismatch',
                    column => $col_name,
                    database_value => $db_col->{is_auto_increment} ? 'YES' : 'NO',
                    result_value => $result_col->{is_auto_increment} ? 'YES' : 'NO',
                    description => "Auto-increment mismatch for column '$col_name'"
                };
            }

            if (($db_col->{default_value} // '') ne ($result_col->{default_value} // '')) {
                push @differences, {
                    type => 'column_default_mismatch',
                    column => $col_name,
                    database_value => $db_col->{default_value} // 'NULL',
                    result_value => $result_col->{default_value} // 'NULL',
                    description => "Default value mismatch for column '$col_name'"
                };
            }

            if (($db_col->{extra} || '') ne ($result_col->{extra} || '')) {
                push @differences, {
                    type => 'column_extra_mismatch',
                    column => $col_name,
                    database_value => $db_col->{extra} || 'N/A',
                    result_value => $result_col->{extra} || 'N/A',
                    description => "Extra attributes mismatch for column '$col_name'"
                };
            }
        }
    }

    # Primary Keys
    my @db_pks = sort @{$db_schema->{primary_keys} || []};
    my @result_pks = sort @{$result_schema->{primary_keys} || []};

    if (join(',', @db_pks) ne join(',', @result_pks)) {
        push @differences, {
            type => 'primary_key_mismatch',
            attribute => 'set_primary_key',
            database_value => join(', ', @db_pks) || 'None',
            result_value => join(', ', @result_pks) || 'None',
            description => "Primary key mismatch"
        };
    }

    # Unique Constraints
    my %db_uniques = map { ($_->{name} || 'unnamed') => join(',', sort @{$_->{columns}}) } @{$db_schema->{unique_constraints} || []};
    my %result_uniques = map { ($_->{name} || 'unnamed') => join(',', sort @{$_->{columns}}) } @{$result_schema->{unique_constraints} || []};

    foreach my $name (keys %db_uniques) {
        if (!exists $result_uniques{$name}) {
            push @differences, {
                type => 'unique_constraint_missing_in_result',
                attribute => "add_unique_constraint ($name)",
                database_value => $db_uniques{$name},
                result_value => undef,
                description => "Unique constraint '$name' missing in Result file"
            };
        } elsif ($db_uniques{$name} ne $result_uniques{$name}) {
            push @differences, {
                type => 'unique_constraint_mismatch',
                attribute => "add_unique_constraint ($name)",
                database_value => $db_uniques{$name},
                result_value => $result_uniques{$name},
                description => "Unique constraint '$name' column mismatch"
            };
        }
    }

    foreach my $name (keys %result_uniques) {
        if (!exists $db_uniques{$name}) {
            push @differences, {
                type => 'unique_constraint_missing_in_table',
                attribute => "add_unique_constraint ($name)",
                database_value => undef,
                result_value => $result_uniques{$name},
                description => "Unique constraint '$name' exists in Result file but not in database"
            };
        }
    }

    return \@differences;
}

__PACKAGE__->meta->make_immutable;
1;