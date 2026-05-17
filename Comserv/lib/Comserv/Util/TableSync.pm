package Comserv::Util::TableSync;

use strict;
use warnings;
use Try::Tiny;
use POSIX qw(strftime);

my $BATCH_SIZE = 500;

my @TIMESTAMP_COLS = qw(updated_at last_mod_date modified_at last_updated updated_on);

my %MYSQL_TO_PG = (
    'tinyint(1)'  => 'BOOLEAN',
    'tinyint'     => 'SMALLINT',
    'smallint'    => 'SMALLINT',
    'mediumint'   => 'INTEGER',
    'int'         => 'INTEGER',
    'integer'     => 'INTEGER',
    'bigint'      => 'BIGINT',
    'float'       => 'REAL',
    'double'      => 'DOUBLE PRECISION',
    'decimal'     => 'NUMERIC',
    'numeric'     => 'NUMERIC',
    'char'        => 'CHAR',
    'varchar'     => 'VARCHAR',
    'tinytext'    => 'TEXT',
    'text'        => 'TEXT',
    'mediumtext'  => 'TEXT',
    'longtext'    => 'TEXT',
    'tinyblob'    => 'BYTEA',
    'blob'        => 'BYTEA',
    'mediumblob'  => 'BYTEA',
    'longblob'    => 'BYTEA',
    'datetime'    => 'TIMESTAMP',
    'timestamp'   => 'TIMESTAMP',
    'date'        => 'DATE',
    'time'        => 'TIME',
    'year'        => 'SMALLINT',
    'enum'        => 'TEXT',
    'set'         => 'TEXT',
    'json'        => 'JSONB',
    'bit'         => 'BIT',
);

my %PG_TO_MYSQL = (
    'boolean'          => 'TINYINT(1)',
    'smallint'         => 'SMALLINT',
    'integer'          => 'INT',
    'int'              => 'INT',
    'bigint'           => 'BIGINT',
    'real'             => 'FLOAT',
    'double precision' => 'DOUBLE',
    'numeric'          => 'DECIMAL',
    'decimal'          => 'DECIMAL',
    'character varying'=> 'VARCHAR',
    'varchar'          => 'VARCHAR',
    'character'        => 'CHAR',
    'char'             => 'CHAR',
    'text'             => 'TEXT',
    'bytea'            => 'LONGBLOB',
    'timestamp'        => 'DATETIME',
    'timestamp without time zone' => 'DATETIME',
    'timestamp with time zone'    => 'DATETIME',
    'date'             => 'DATE',
    'time'             => 'TIME',
    'time without time zone'      => 'TIME',
    'jsonb'            => 'JSON',
    'json'             => 'JSON',
    'bit'              => 'BIT',
    'uuid'             => 'VARCHAR(36)',
);

sub new {
    my ($class, %args) = @_;
    return bless {
        batch_size  => $args{batch_size}  || $BATCH_SIZE,
        on_progress => $args{on_progress} || sub {},
    }, $class;
}

sub sync {
    my ($self, %opts) = @_;

    my $src_dbh    = $opts{src_dbh}    or die "src_dbh required";
    my $tgt_dbh    = $opts{tgt_dbh}    or die "tgt_dbh required";
    my $src_type   = lc($opts{src_type}   || 'mysql');
    my $tgt_type   = lc($opts{tgt_type}   || 'mysql');
    my $database   = $opts{database}   || '';
    my $tables     = $opts{tables}     || [];
    my $schema_only   = $opts{schema_only}   || 0;
    my $incremental   = $opts{incremental}   || 0;
    my $since         = $opts{since}         || '';
    my $drop_target   = $opts{drop_target}   || 0;

    my @results;
    my $total_rows = 0;
    my $total_errors = 0;

    my @table_list = @$tables;
    if (!@table_list) {
        @table_list = $self->_list_tables($src_dbh, $src_type, $database);
    }

    $self->{on_progress}->("Found " . scalar(@table_list) . " tables to sync\n");

    for my $table (@table_list) {
        my $t_start = time();
        my $result  = {
            table       => $table,
            rows_synced => 0,
            rows_failed => 0,
            skipped     => 0,
            error       => '',
            duration    => 0,
        };

        $self->{on_progress}->("Syncing table: $table\n");

        try {
            my $cols = $self->_get_columns($src_dbh, $src_type, $table, $database);
            unless (@$cols) {
                $result->{skipped} = 1;
                $result->{error}   = 'No columns found (view or permission issue)';
                $self->{on_progress}->("  SKIPPED: $table — no columns\n");
                push @results, $result;
                return;
            }

            if ($drop_target && !$schema_only) {
                $self->_drop_table($tgt_dbh, $tgt_type, $table);
            }

            my $tbl_created = $self->_ensure_table($src_dbh, $tgt_dbh, $src_type, $tgt_type, $table, $cols, $database);
            $self->{on_progress}->("  " . ($tbl_created ? "Created" : "Exists") . ": $table\n") if $tbl_created;

            unless ($schema_only) {
                my $pk_cols     = [grep { $_->{is_primary} } @$cols];
                my $ts_col      = $self->_find_timestamp_col($cols);
                my $where_clause = '';
                my @where_bind;

                if ($incremental && $ts_col && $since) {
                    $where_clause = " WHERE $ts_col > ?";
                    @where_bind   = ($since);
                    $self->{on_progress}->("  Incremental: $ts_col > $since\n");
                }

                my $col_names  = join(', ', map { $self->_quote($src_type, $_->{name}) } @$cols);
                my $count_sth  = $src_dbh->prepare("SELECT COUNT(*) FROM " . $self->_quote_table($src_type, $table, $database) . $where_clause);
                $count_sth->execute(@where_bind);
                my ($total) = $count_sth->fetchrow_array();
                $count_sth->finish();

                $self->{on_progress}->("  Rows to sync: $total\n");

                my $offset = 0;
                while ($offset < $total) {
                    my $limit_sql = $self->_limit_sql($src_type, $self->{batch_size}, $offset);
                    my $sth = $src_dbh->prepare(
                        "SELECT $col_names FROM " . $self->_quote_table($src_type, $table, $database) .
                        $where_clause . " ORDER BY " . $self->_quote($src_type, $cols->[0]{name}) .
                        " $limit_sql"
                    );
                    $sth->execute(@where_bind);

                    my @batch;
                    while (my $row = $sth->fetchrow_arrayref()) {
                        push @batch, [@$row];
                    }
                    $sth->finish();
                    last unless @batch;

                    my ($synced, $failed) = $self->_insert_batch(
                        $tgt_dbh, $tgt_type, $table, $cols, \@batch, $pk_cols, $database
                    );
                    $result->{rows_synced} += $synced;
                    $result->{rows_failed} += $failed;
                    $offset += scalar(@batch);

                    $self->{on_progress}->("  Progress: $offset/$total\n") if $offset % 2000 == 0 || $offset >= $total;
                }
            }
        } catch {
            my $err = "$_";
            $err =~ s/\n/ /g;
            $result->{error} = $err;
            $total_errors++;
            $self->{on_progress}->("  ERROR: $err\n");
        };

        $result->{duration}  = time() - $t_start;
        $total_rows         += $result->{rows_synced};
        push @results, $result;
        $self->{on_progress}->(sprintf("  Done: %d rows in %ds\n", $result->{rows_synced}, $result->{duration}));
    }

    $self->{on_progress}->(sprintf("\nSync complete: %d rows across %d tables (%d errors)\n",
        $total_rows, scalar(@table_list), $total_errors));

    return {
        tables       => \@results,
        total_rows   => $total_rows,
        total_errors => $total_errors,
        table_count  => scalar(@table_list),
    };
}

sub _list_tables {
    my ($self, $dbh, $db_type, $database) = @_;
    if ($db_type eq 'mysql') {
        my $sql = $database
            ? "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = ? AND TABLE_TYPE = 'BASE TABLE' ORDER BY TABLE_NAME"
            : "SELECT CONCAT(TABLE_SCHEMA,'.',TABLE_NAME) FROM information_schema.TABLES WHERE TABLE_SCHEMA NOT IN ('information_schema','performance_schema','sys','mysql') AND TABLE_TYPE = 'BASE TABLE' ORDER BY TABLE_SCHEMA,TABLE_NAME";
        my $sth = $dbh->prepare($sql);
        $database ? $sth->execute($database) : $sth->execute();
        my @tables;
        while (my ($t) = $sth->fetchrow_array()) { push @tables, $t }
        $sth->finish();
        return @tables;
    } else {
        my $schema = $database || 'public';
        my $sth = $dbh->prepare(
            "SELECT tablename FROM pg_tables WHERE schemaname = ? ORDER BY tablename"
        );
        $sth->execute($schema);
        my @tables;
        while (my ($t) = $sth->fetchrow_array()) { push @tables, $t }
        $sth->finish();
        return @tables;
    }
}

sub _get_columns {
    my ($self, $dbh, $db_type, $table, $database) = @_;
    my @cols;
    if ($db_type eq 'mysql') {
        my ($schema, $tbl) = $table =~ /\./ ? split(/\./, $table, 2) : ($database, $table);
        $schema ||= $database;
        my $sth = $dbh->prepare(
            "SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_KEY, COLUMN_DEFAULT, EXTRA
             FROM information_schema.COLUMNS
             WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?
             ORDER BY ORDINAL_POSITION"
        );
        $sth->execute($schema, $tbl);
        while (my $row = $sth->fetchrow_hashref()) {
            push @cols, {
                name       => $row->{COLUMN_NAME},
                type       => $row->{COLUMN_TYPE},
                nullable   => $row->{IS_NULLABLE} eq 'YES' ? 1 : 0,
                is_primary => $row->{COLUMN_KEY} eq 'PRI' ? 1 : 0,
                default    => $row->{COLUMN_DEFAULT},
                extra      => $row->{EXTRA},
            };
        }
        $sth->finish();
    } else {
        my $schema = $database || 'public';
        my $sth = $dbh->prepare(
            "SELECT c.column_name, c.data_type, c.is_nullable, c.column_default,
                    c.character_maximum_length, c.numeric_precision, c.numeric_scale,
                    CASE WHEN pk.column_name IS NOT NULL THEN 'PRI' ELSE '' END AS column_key
             FROM information_schema.columns c
             LEFT JOIN (
                 SELECT kcu.column_name
                 FROM information_schema.table_constraints tc
                 JOIN information_schema.key_column_usage kcu
                   ON tc.constraint_name = kcu.constraint_name
                  AND tc.table_schema = kcu.table_schema
                 WHERE tc.constraint_type = 'PRIMARY KEY'
                   AND tc.table_schema = ? AND tc.table_name = ?
             ) pk ON pk.column_name = c.column_name
             WHERE c.table_schema = ? AND c.table_name = ?
             ORDER BY c.ordinal_position"
        );
        $sth->execute($schema, $table, $schema, $table);
        while (my $row = $sth->fetchrow_hashref()) {
            my $full_type = $row->{data_type};
            if ($row->{character_maximum_length}) {
                $full_type .= "($row->{character_maximum_length})";
            } elsif ($row->{numeric_precision} && $row->{numeric_scale}) {
                $full_type .= "($row->{numeric_precision},$row->{numeric_scale})";
            }
            push @cols, {
                name       => $row->{column_name},
                type       => $full_type,
                nullable   => $row->{is_nullable} eq 'YES' ? 1 : 0,
                is_primary => ($row->{column_key} || '') eq 'PRI' ? 1 : 0,
                default    => $row->{column_default},
                extra      => '',
            };
        }
        $sth->finish();
    }
    return \@cols;
}

sub _find_timestamp_col {
    my ($self, $cols) = @_;
    my %col_map = map { lc($_->{name}) => $_->{name} } @$cols;
    for my $ts (@TIMESTAMP_COLS) {
        return $col_map{$ts} if exists $col_map{$ts};
    }
    return undef;
}

sub _map_type {
    my ($self, $src_type, $tgt_type, $col_type) = @_;
    return $col_type if $src_type eq $tgt_type;
    my $base = lc($col_type);
    $base =~ s/\s*\(.*\)//;
    $base =~ s/\s+unsigned//;
    my $size = '';
    if ($col_type =~ /\(([^)]+)\)/) { $size = "($1)"; }

    if ($src_type eq 'mysql' && $tgt_type eq 'postgres') {
        if ($base eq 'tinyint' && $size eq '(1)') { return 'BOOLEAN'; }
        my $mapped = $MYSQL_TO_PG{$base} || 'TEXT';
        if ($mapped =~ /^(VARCHAR|CHAR|NUMERIC|DECIMAL|BIT)$/ && $size) {
            return "$mapped$size";
        }
        return $mapped;
    } elsif ($src_type eq 'postgres' && $tgt_type eq 'mysql') {
        my $mapped = $PG_TO_MYSQL{$base} || 'TEXT';
        if ($mapped =~ /^(VARCHAR|CHAR|DECIMAL|NUMERIC)$/ && $size) {
            return "$mapped$size";
        }
        return $mapped;
    }
    return $col_type;
}

sub _ensure_table {
    my ($self, $src_dbh, $tgt_dbh, $src_type, $tgt_type, $table, $cols, $database) = @_;

    my $tbl_name   = $table;
    $tbl_name =~ s/.*\.//;
    my $tgt_schema = $tgt_type eq 'postgres' ? ($database || 'public') : undef;

    my $exists = $self->_table_exists($tgt_dbh, $tgt_type, $tbl_name, $tgt_schema);
    return 0 if $exists;

    my @col_defs;
    my @pk_cols;
    for my $col (@$cols) {
        next if $col->{extra} =~ /auto_increment/i && $tgt_type eq 'postgres';
        my $type = $self->_map_type($src_type, $tgt_type, $col->{type});
        my $null = $col->{nullable} ? '' : ' NOT NULL';
        my $def  = '';
        if ($tgt_type eq 'postgres' && $col->{extra} =~ /auto_increment/i) {
            $type = 'SERIAL';
            $null = '';
        }
        push @col_defs, $self->_quote($tgt_type, $col->{name}) . " $type$null";
        push @pk_cols, $self->_quote($tgt_type, $col->{name}) if $col->{is_primary};
    }
    push @col_defs, "PRIMARY KEY (" . join(', ', @pk_cols) . ")" if @pk_cols;

    my $tbl_ref = $tgt_type eq 'postgres'
        ? ($tgt_schema ? "\"$tgt_schema\".\"$tbl_name\"" : "\"$tbl_name\"")
        : "`$tbl_name`";

    my $ddl = "CREATE TABLE IF NOT EXISTS $tbl_ref (\n  " . join(",\n  ", @col_defs) . "\n)";
    eval { $tgt_dbh->do($ddl) };
    if ($@) {
        my $err = $@;
        die "CREATE TABLE failed for $tbl_name: $err\nDDL: $ddl\n";
    }
    return 1;
}

sub _table_exists {
    my ($self, $dbh, $db_type, $table, $schema) = @_;
    if ($db_type eq 'mysql') {
        my ($count) = $dbh->selectrow_array(
            "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_NAME = ? AND TABLE_TYPE='BASE TABLE'",
            undef, $table
        );
        return $count > 0;
    } else {
        $schema //= 'public';
        my ($count) = $dbh->selectrow_array(
            "SELECT COUNT(*) FROM pg_tables WHERE tablename = ? AND schemaname = ?",
            undef, $table, $schema
        );
        return $count > 0;
    }
}

sub _drop_table {
    my ($self, $dbh, $db_type, $table) = @_;
    my $quoted = $db_type eq 'postgres' ? "\"$table\"" : "`$table`";
    eval { $dbh->do("DROP TABLE IF EXISTS $quoted") };
}

sub _insert_batch {
    my ($self, $tgt_dbh, $tgt_type, $table, $cols, $rows, $pk_cols, $database) = @_;
    return (0, 0) unless @$rows;

    my $tbl_name = $table;
    $tbl_name =~ s/.*\.//;
    my $schema = $tgt_type eq 'postgres' ? ($database || 'public') : undef;
    my $tbl_ref = $self->_quote_table($tgt_type, $tbl_name, $schema);

    my @col_names  = map { $_->{name} } @$cols;
    my @quoted_cols = map { $self->_quote($tgt_type, $_) } @col_names;
    my $placeholders = join(', ', ('?') x scalar(@col_names));
    my $col_list     = join(', ', @quoted_cols);

    my $sql;
    if ($tgt_type eq 'mysql') {
        my @updates = map { $self->_quote('mysql', $_) . " = VALUES(" . $self->_quote('mysql', $_) . ")" }
                      grep { !grep { $_->{name} eq $_ } @$pk_cols } @col_names;
        if (@updates) {
            $sql = "INSERT INTO $tbl_ref ($col_list) VALUES ($placeholders) ON DUPLICATE KEY UPDATE " . join(', ', @updates);
        } else {
            $sql = "INSERT IGNORE INTO $tbl_ref ($col_list) VALUES ($placeholders)";
        }
    } else {
        if (@$pk_cols) {
            my @pk_names = map { $_->{name} } @$pk_cols;
            my @non_pk   = grep { my $n = $_; !grep { $_->{name} eq $n } @$pk_cols } @$cols;
            if (@non_pk) {
                my @updates = map { $self->_quote('postgres', $_->{name}) . " = EXCLUDED." . $self->_quote('postgres', $_->{name}) } @non_pk;
                $sql = "INSERT INTO $tbl_ref ($col_list) VALUES ($placeholders) ON CONFLICT (" .
                       join(', ', map { $self->_quote('postgres', $_) } @pk_names) .
                       ") DO UPDATE SET " . join(', ', @updates);
            } else {
                $sql = "INSERT INTO $tbl_ref ($col_list) VALUES ($placeholders) ON CONFLICT DO NOTHING";
            }
        } else {
            $sql = "INSERT INTO $tbl_ref ($col_list) VALUES ($placeholders) ON CONFLICT DO NOTHING";
        }
    }

    my $sth     = $tgt_dbh->prepare($sql);
    my $synced  = 0;
    my $failed  = 0;

    for my $row (@$rows) {
        my @values = map {
            my $v = $row->[$_];
            if ($tgt_type eq 'postgres' && defined $v) {
                my $col_type = lc($cols->[$_]{type} || '');
                if ($col_type =~ /\bbool/) {
                    $v = ($v && $v ne '0') ? 'true' : 'false';
                }
            }
            $v
        } 0..$#$row;

        my $ok = eval { $sth->execute(@values); 1 };
        if ($ok) { $synced++ } else { $failed++ }
    }
    $sth->finish();
    return ($synced, $failed);
}

sub _quote {
    my ($self, $db_type, $name) = @_;
    return $db_type eq 'postgres' ? "\"$name\"" : "`$name`";
}

sub _quote_table {
    my ($self, $db_type, $table, $schema) = @_;
    my $bare = $table;
    $bare =~ s/.*\.//;
    if ($db_type eq 'postgres') {
        my $s = $schema || 'public';
        return "\"$s\".\"$bare\"";
    } else {
        if ($table =~ /\./) {
            my ($db, $tbl) = split(/\./, $table, 2);
            return "`$db`.`$tbl`";
        }
        return "`$bare`";
    }
}

sub _limit_sql {
    my ($self, $db_type, $limit, $offset) = @_;
    return " LIMIT $limit OFFSET $offset";
}

1;
