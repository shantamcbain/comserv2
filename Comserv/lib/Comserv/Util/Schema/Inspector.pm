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

1;