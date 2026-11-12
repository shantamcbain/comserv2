# AI-REMINDER: keep file < 1 500 lines; follow .ai-policy.md
package Comserv::Util::Schema::Inspector;

use strict;
use warnings;
use Try::Tiny;
use DBI;

=head1 NAME

Comserv::Util::Schema::Inspector - Cross-DB (MySQL/Postgres) table listing + schema introspection

Provides a unified shape:
  { columns => { colname => {data_type, size, is_nullable, default_value, is_auto_increment, extra, ...} },
    primary_keys => [], unique_constraints => [], foreign_keys => [] }

Used by Comparator so that ency/forager + migration mysql + migration postgres all feed the
same display code in schema_compare.tt .

=cut

sub new {
    my ($class, %args) = @_;
    return bless { logging => $args{logging} }, $class;
}

sub logging {
    my $self = shift;
    return $self->{logging} if $self->{logging};
    require Comserv::Util::Logging;
    return Comserv::Util::Logging->new();
}

# Resolve a dbh or model key to a connected dbh + engine hint
sub _get_dbh_and_engine {
    my ($self, $source, $c) = @_;  # source can be 'ency'|'forager' or a live $dbh
    if (ref($source) && $source->isa('DBI::db')) {
        my $drv = $source->{Driver}{Name} || 'unknown';
        return ($source, lc($drv) =~ /pg/ ? 'pg' : 'mysql');
    }
    # assume catalyst context + model key
    return (undef, 'unknown') unless $c;
    my $model_name = (lc($source || '') eq 'forager') ? 'DBForager' : 'DBEncy';
    my $schema = eval { $c->model($model_name)->schema };
    my $dbh = eval { $schema->storage->dbh } if $schema;
    my $drv = $dbh ? ($dbh->{Driver}{Name} || '') : '';
    my $engine = lc($drv) =~ /pg/ ? 'pg' : 'mysql';
    return ($dbh, $engine);
}

sub list_tables {
    my ($self, $source, $c) = @_;
    my ($dbh, $engine) = $self->_get_dbh_and_engine($source, $c);
    return [] unless $dbh;

    my @tables;
    try {
        if ($engine eq 'pg') {
            my $sth = $dbh->prepare(q{
                SELECT tablename FROM pg_tables
                WHERE schemaname = 'public' ORDER BY tablename
            });
            $sth->execute();
            while (my ($t) = $sth->fetchrow_array) { push @tables, $t; }
        } else {
            # mysql / mariadb
            my $sth = $dbh->prepare("SHOW TABLES");
            $sth->execute();
            while (my ($t) = $sth->fetchrow_array) { push @tables, $t; }
        }
    } catch {
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'list_tables', "list failed: $_");
    };
    return \@tables;
}

sub get_table_schema {
    my ($self, $source, $table_name, $c) = @_;
    my ($dbh, $engine) = $self->_get_dbh_and_engine($source, $c);
    return { columns => {}, primary_keys => [], unique_constraints => [], foreign_keys => [] } unless $dbh;

    my $info = {
        columns => {},
        primary_keys => [],
        unique_constraints => [],
        foreign_keys => [],
    };

    try {
        if ($engine eq 'pg') {
            # information_schema + pg constraints
            my $csth = $dbh->prepare(q{
                SELECT column_name, data_type, character_maximum_length,
                       is_nullable, column_default
                FROM information_schema.columns
                WHERE table_schema = 'public' AND table_name = ?
                ORDER BY ordinal_position
            });
            $csth->execute($table_name);
            while (my $row = $csth->fetchrow_hashref()) {
                my $col = $row->{column_name};
                $info->{columns}->{$col} = {
                    data_type => $row->{data_type},
                    size => $row->{character_maximum_length},
                    is_nullable => ($row->{is_nullable} eq 'YES' ? 1 : 0),
                    default_value => $row->{column_default},
                    is_auto_increment => 0,  # pg usually uses sequences
                    extra => '',
                };
            }

            # primary keys
            my $pksth = $dbh->prepare(q{
                SELECT a.attname
                FROM pg_index i
                JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
                WHERE i.indrelid = ?::regclass AND i.indisprimary
            });
            $pksth->execute($table_name);
            while (my ($pk) = $pksth->fetchrow_array) { push @{$info->{primary_keys}}, $pk; }

            # simple uniques (non-pk)
            # (omitted for brevity in initial split; can be expanded)
        } else {
            # mysql
            my $sth = $dbh->prepare("DESCRIBE `$table_name`");
            $sth->execute();
            while (my $row = $sth->fetchrow_hashref()) {
                my $col = $row->{Field};
                my $type = $row->{Type} || '';
                my $size;
                if ($type =~ /\((\d+(?:,\d+)?)\)/) { $size = $1; $type =~ s/\(.*\)//; }
                $info->{columns}->{$col} = {
                    data_type => $type,
                    size => $size,
                    is_nullable => ($row->{Null} eq 'YES' ? 1 : 0),
                    default_value => $row->{Default},
                    is_auto_increment => ($row->{Extra} =~ /auto_increment/i ? 1 : 0),
                    extra => $row->{Extra} || '',
                };
                if ($row->{Key} eq 'PRI') {
                    push @{$info->{primary_keys}}, $col;
                }
            }

            # FKs via info schema (same as before)
            my $fksth = $dbh->prepare(q{
                SELECT COLUMN_NAME, REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME
                FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE
                WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND REFERENCED_TABLE_NAME IS NOT NULL
            });
            $fksth->execute($table_name);
            while (my $r = $fksth->fetchrow_hashref()) {
                push @{$info->{foreign_keys}}, {
                    column => $r->{COLUMN_NAME},
                    referenced_table => $r->{REFERENCED_TABLE_NAME},
                    referenced_column => $r->{REFERENCED_COLUMN_NAME},
                };
            }

            # uniques (non pk)
            my $uqsth = $dbh->prepare("SHOW INDEX FROM `$table_name` WHERE Non_unique = 0 AND Key_name != 'PRIMARY'");
            $uqsth->execute();
            my %uq;
            while (my $r = $uqsth->fetchrow_hashref()) {
                push @{ $uq{ $r->{Key_name} } }, $r->{Column_name};
            }
            foreach my $k (sort keys %uq) {
                push @{$info->{unique_constraints}}, { name => $k, columns => $uq{$k} };
            }
        }
    } catch {
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'get_table_schema', "describe $table_name ($engine): $_");
    };

    return $info;
}


# ---------------------------------------------------------------------------
# Bulk catalog — one query for every column / key in the database, so the
# tables-list page can flag Result-vs-live drift without N+1 DESCRIBE calls.
# Column hashes match _dbh_list_columns in SchemaComparison (size keeps its
# parentheses; is_nullable is YES/NO) so the list and the field grid agree.
# ---------------------------------------------------------------------------

sub _row {
    my ($row, @keys) = @_;
    # information_schema column-name case varies by driver / FetchHashKeyName.
    for my $k (@keys) {
        return $row->{$k} if exists $row->{$k} && defined $row->{$k};
        my $lc = lc $k;
        return $row->{$lc} if exists $row->{$lc} && defined $row->{$lc};
        my $uc = uc $k;
        return $row->{$uc} if exists $row->{$uc} && defined $row->{$uc};
    }
    return undef;
}

sub list_all_columns {
    my ($self, $dbh, $db_name, $is_pg) = @_;
    my %by_table;    # lc(table) => { lc(col) => { ... } }
    return \%by_table unless $dbh;

    try {
        if ($is_pg) {
            my $sth = $dbh->prepare(q{
                SELECT table_name, column_name, udt_name,
                       character_maximum_length, numeric_precision, numeric_scale,
                       is_nullable, column_default
                  FROM information_schema.columns
                 WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
                 ORDER BY table_name, ordinal_position
            });
            $sth->execute();
            while (my $row = $sth->fetchrow_hashref) {
                my $tname = _row($row, 'table_name') // next;
                my $cname = _row($row, 'column_name') // next;
                my $dt    = _row($row, 'udt_name') // '';
                my $size  = '';
                my $cml   = _row($row, 'character_maximum_length');
                my $np    = _row($row, 'numeric_precision');
                my $ns    = _row($row, 'numeric_scale');
                if (defined $cml) {
                    $size = '(' . $cml . ')';
                }
                elsif (defined $np) {
                    $size = defined $ns ? "($np,$ns)" : "($np)";
                }
                my $def = _row($row, 'column_default');
                $def =~ s/::[\w\s]+$// if defined $def;
                my $null = _row($row, 'is_nullable') // 'YES';
                $by_table{ lc($tname) }{ lc($cname) } = {
                    name          => $cname,
                    data_type     => $dt,
                    size          => $size,
                    is_nullable   => $null eq 'NO' ? 'NO' : 'YES',
                    default_value => $def,
                    extra         => '',
                    comment       => '',
                };
            }
            $sth->finish;
        }
        else {
            my $sth = $dbh->prepare(q{
                SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE, COLUMN_TYPE,
                       IS_NULLABLE, COLUMN_DEFAULT, EXTRA, COLUMN_COMMENT
                  FROM information_schema.COLUMNS
                 WHERE TABLE_SCHEMA = ?
                 ORDER BY TABLE_NAME, ORDINAL_POSITION
            });
            $sth->execute($db_name);
            while (my $row = $sth->fetchrow_hashref) {
                my $tname    = _row($row, 'TABLE_NAME') // next;
                my $cname    = _row($row, 'COLUMN_NAME') // next;
                my $type_raw = _row($row, 'COLUMN_TYPE') // '';
                my ($data_type, $size) = $type_raw =~ /^(\w+)(\([^)]+\))?/;
                $size //= '';
                if ($data_type && $data_type =~ /^(enum|set)$/i) {
                    $data_type = $type_raw;
                    $size      = '';
                }
                my $null = _row($row, 'IS_NULLABLE') // 'YES';
                $by_table{ lc($tname) }{ lc($cname) } = {
                    name          => $cname,
                    data_type     => $data_type // $type_raw,
                    size          => $size,
                    is_nullable   => $null eq 'NO' ? 'NO' : 'YES',
                    default_value => _row($row, 'COLUMN_DEFAULT'),
                    extra         => _row($row, 'EXTRA') // '',
                    comment       => _row($row, 'COLUMN_COMMENT') // '',
                };
            }
            $sth->finish;
        }
    } catch {
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__,
            'list_all_columns', "bulk columns failed: $_");
    };
    return \%by_table;
}

sub list_all_keys {
    my ($self, $dbh, $db_name, $is_pg) = @_;
    my %by_table;    # lc(table) => { primary_keys => [], uniques => [ {name, columns} ] }
    return \%by_table unless $dbh;

    try {
        if ($is_pg) {
            my $sth = $dbh->prepare(q{
                SELECT tc.table_name, tc.constraint_name, tc.constraint_type,
                       kcu.column_name, kcu.ordinal_position
                  FROM information_schema.table_constraints tc
                  JOIN information_schema.key_column_usage kcu
                    ON tc.constraint_name = kcu.constraint_name
                   AND tc.table_schema    = kcu.table_schema
                   AND tc.table_name      = kcu.table_name
                 WHERE tc.table_schema NOT IN ('pg_catalog', 'information_schema')
                   AND tc.constraint_type IN ('PRIMARY KEY', 'UNIQUE')
                 ORDER BY tc.table_name, tc.constraint_name, kcu.ordinal_position
            });
            $sth->execute();
            my %pk;
            my %uq;
            while (my $row = $sth->fetchrow_hashref) {
                my $tname = _row($row, 'table_name') // next;
                my $cname = _row($row, 'column_name') // next;
                my $kname = _row($row, 'constraint_name') // '';
                my $ctype = _row($row, 'constraint_type') // '';
                if ($ctype =~ /PRIMARY/i) {
                    push @{ $pk{ lc($tname) } }, $cname;
                }
                else {
                    push @{ $uq{ lc($tname) }{$kname} }, $cname;
                }
            }
            $sth->finish;
            for my $t (keys %pk, keys %uq) {
                $by_table{$t} ||= { primary_keys => [], uniques => [] };
            }
            for my $t (keys %pk) {
                $by_table{$t}{primary_keys} = $pk{$t};
            }
            for my $t (keys %uq) {
                $by_table{$t}{uniques} = [
                    map { { name => $_, columns => $uq{$t}{$_} } } sort keys %{ $uq{$t} }
                ];
            }
        }
        else {
            my $sth = $dbh->prepare(q{
                SELECT TABLE_NAME, INDEX_NAME, NON_UNIQUE, SEQ_IN_INDEX, COLUMN_NAME
                  FROM information_schema.STATISTICS
                 WHERE TABLE_SCHEMA = ?
                 ORDER BY TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX
            });
            $sth->execute($db_name);
            my %pk;
            my %uq;
            while (my $row = $sth->fetchrow_hashref) {
                my $tname = _row($row, 'TABLE_NAME') // next;
                my $cname = _row($row, 'COLUMN_NAME') // next;
                my $kname = _row($row, 'INDEX_NAME') // '';
                my $nu    = _row($row, 'NON_UNIQUE');
                $nu = 1 unless defined $nu;
                if ($kname eq 'PRIMARY') {
                    push @{ $pk{ lc($tname) } }, $cname;
                }
                elsif ($nu == 0 || $nu eq '0') {
                    push @{ $uq{ lc($tname) }{$kname} }, $cname;
                }
                # Non-unique indexes are intentionally ignored (do not flag
                # extra live indexes the Result file never declared).
            }
            $sth->finish;
            for my $t (keys %pk, keys %uq) {
                $by_table{$t} ||= { primary_keys => [], uniques => [] };
            }
            for my $t (keys %pk) {
                $by_table{$t}{primary_keys} = $pk{$t};
            }
            for my $t (keys %uq) {
                $by_table{$t}{uniques} = [
                    map { { name => $_, columns => $uq{$t}{$_} } } sort keys %{ $uq{$t} }
                ];
            }
        }
    } catch {
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__,
            'list_all_keys', "bulk keys failed: $_");
    };
    return \%by_table;
}


1;
