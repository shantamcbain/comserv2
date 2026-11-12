package Comserv::Util::DatabaseCompare;

use strict;
use warnings;

=head1 NAME

Comserv::Util::DatabaseCompare - read-only diff of two database catalogs

=head1 DESCRIPTION

Compares table presence, approximate row counts, and column shape.
Does not read cell values and does not write.

=cut

my %SKIP_SCHEMA = map { $_ => 1 } qw(
    mysql information_schema performance_schema sys
    pg_catalog template0 template1
);

sub catalog_counts {
    my ($class, $dbh, $is_pg) = @_;
    return [] unless $dbh;

    my @rows;
    if ($is_pg) {
        my $current = eval { $dbh->selectrow_array('SELECT current_database()') } // '';
        my ($table_count, $row_count) = (undef, undef);
        eval {
            my $sth = $dbh->prepare(q{
                SELECT COUNT(*), COALESCE(SUM(c.reltuples), 0)::bigint
                  FROM pg_catalog.pg_class c
                  JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
                 WHERE c.relkind = 'r'
                   AND n.nspname NOT IN ('pg_catalog', 'information_schema')
            });
            $sth->execute();
            ($table_count, $row_count) = $sth->fetchrow_array;
            $sth->finish;
        };
        my $sth = $dbh->prepare(q{
            SELECT datname
              FROM pg_database
             WHERE datistemplate = false
             ORDER BY 1
        });
        $sth->execute();
        while (my ($name) = $sth->fetchrow_array) {
            next if $SKIP_SCHEMA{$name};
            my $here = lc($name) eq lc($current);
            push @rows, {
                name        => $name,
                table_count => $here ? ($table_count || 0) : undef,
                row_count   => $here ? ($row_count   || 0) : undef,
            };
        }
        $sth->finish;
        return \@rows;
    }

    my $sth = $dbh->prepare(q{
        SELECT s.schema_name,
               COUNT(t.table_name) AS table_count,
               COALESCE(SUM(t.table_rows), 0) AS row_count
          FROM information_schema.schemata s
          LEFT JOIN information_schema.tables t
            ON t.table_schema = s.schema_name
           AND t.table_type = 'BASE TABLE'
         WHERE s.schema_name NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
         GROUP BY s.schema_name
         ORDER BY s.schema_name
    });
    $sth->execute();
    while (my $row = $sth->fetchrow_hashref) {
        push @rows, {
            name        => $row->{schema_name},
            table_count => $row->{table_count} || 0,
            row_count   => $row->{row_count}   || 0,
        };
    }
    $sth->finish;
    return \@rows;
}

sub snapshot {
    my ($class, $dbh, $database, $is_pg, $meta) = @_;
    die "database name required\n" unless defined $database && $database =~ /\A[A-Za-z0-9_]+\z/;
    die "handle required\n" unless $dbh;

    my %tables;
    if ($is_pg) {
        my $sth = $dbh->prepare(q{
            SELECT c.relname AS table_name,
                   COALESCE(c.reltuples, 0)::bigint AS table_rows
              FROM pg_catalog.pg_class c
              JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
             WHERE c.relkind = 'r'
               AND n.nspname = 'public'
        });
        $sth->execute();
        while (my $row = $sth->fetchrow_hashref) {
            $tables{ $row->{table_name} } = {
                row_count => $row->{table_rows} || 0,
                columns   => {},
            };
        }
        $sth->finish;

        $sth = $dbh->prepare(q{
            SELECT table_name, column_name, data_type, is_nullable
              FROM information_schema.columns
             WHERE table_schema = 'public'
               AND table_catalog = ?
        });
        $sth->execute($database);
        while (my $row = $sth->fetchrow_hashref) {
            my $t = $tables{ $row->{table_name} } ||= { row_count => undef, columns => {} };
            $t->{columns}{ $row->{column_name} } = {
                data_type   => lc($row->{data_type} // ''),
                is_nullable => uc($row->{is_nullable} // ''),
            };
        }
        $sth->finish;
    }
    else {
        my $sth = $dbh->prepare(q{
            SELECT table_name, table_rows
              FROM information_schema.tables
             WHERE table_schema = ?
               AND table_type = 'BASE TABLE'
        });
        $sth->execute($database);
        while (my $row = $sth->fetchrow_hashref) {
            $tables{ $row->{table_name} } = {
                row_count => defined $row->{table_rows} ? $row->{table_rows} : undef,
                columns   => {},
            };
        }
        $sth->finish;

        $sth = $dbh->prepare(q{
            SELECT table_name, column_name, data_type, is_nullable
              FROM information_schema.columns
             WHERE table_schema = ?
        });
        $sth->execute($database);
        while (my $row = $sth->fetchrow_hashref) {
            my $t = $tables{ $row->{table_name} } ||= { row_count => undef, columns => {} };
            $t->{columns}{ $row->{column_name} } = {
                data_type   => lc($row->{data_type} // ''),
                is_nullable => uc($row->{is_nullable} // ''),
            };
        }
        $sth->finish;
    }

    return {
        connection => $meta->{connection} // '',
        host       => $meta->{host}       // '',
        port       => $meta->{port}       // '',
        database   => $database,
        engine     => $is_pg ? 'postgresql' : 'mysql',
        tables     => \%tables,
    };
}

sub diff_pair {
    my ($class, $left, $right) = @_;
    my $lt = $left->{tables}  || {};
    my $rt = $right->{tables} || {};

    my %names;
    $names{$_} = 1 for keys %$lt, keys %$rt;

    my (@only_left, @only_right, @data, @schema);
    for my $name (sort keys %names) {
        my $L = $lt->{$name};
        my $R = $rt->{$name};
        if ($L && !$R) {
            push @only_left, { name => $name, row_count => $L->{row_count} };
            next;
        }
        if ($R && !$L) {
            push @only_right, { name => $name, row_count => $R->{row_count} };
            next;
        }

        my ($lc, $rc) = ($L->{row_count}, $R->{row_count});
        my $status = 'count_unknown';
        if (defined $lc && defined $rc) {
            if ($lc > 0 && $rc == 0) {
                $status = 'missing_on_right';
            }
            elsif ($rc > 0 && $lc == 0) {
                $status = 'missing_on_left';
            }
            elsif ($lc != $rc) {
                $status = 'count_differs';
            }
            else {
                $status = 'counts_match';
            }
        }
        push @data, {
            name       => $name,
            left_rows  => $lc,
            right_rows => $rc,
            status     => $status,
        };

        my $lcols = $L->{columns} || {};
        my $rcols = $R->{columns} || {};
        my %cols;
        $cols{$_} = 1 for keys %$lcols, keys %$rcols;
        my (@col_left, @col_right, @types);
        for my $col (sort keys %cols) {
            if ($lcols->{$col} && !$rcols->{$col}) {
                push @col_left, $col;
            }
            elsif ($rcols->{$col} && !$lcols->{$col}) {
                push @col_right, $col;
            }
            elsif (($lcols->{$col}{data_type} // '') ne ($rcols->{$col}{data_type} // '')
                || ($lcols->{$col}{is_nullable} // '') ne ($rcols->{$col}{is_nullable} // '')) {
                push @types, $col;
            }
        }
        if (@col_left || @col_right || @types) {
            push @schema, {
                name                 => $name,
                columns_only_left    => \@col_left,
                columns_only_right   => \@col_right,
                type_mismatches      => \@types,
            };
        }
    }

    @data = sort {
        _rank($a->{status}) <=> _rank($b->{status}) || $a->{name} cmp $b->{name}
    } @data;

    return {
        tables_only_left  => \@only_left,
        tables_only_right => \@only_right,
        data              => \@data,
        schema            => \@schema,
    };
}

sub _rank {
    my ($status) = @_;
    return 0 if $status eq 'missing_on_right' || $status eq 'missing_on_left';
    return 1 if $status eq 'count_differs';
    return 2 if $status eq 'count_unknown';
    return 3;
}

1;
