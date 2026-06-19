# AI-REMINDER: keep file < 1 500 lines; follow .ai-policy.md
package Comserv::Util::Schema::ResultParser;

use strict;
use warnings;
use File::Basename qw(dirname);
use File::Spec;
use Try::Tiny;

=head1 NAME

Comserv::Util::Schema::ResultParser - Discovery and parsing of DBIx::Class Result files

Extracted and consolidated from Admin.pm + SchemaComparison.pm to keep controllers thin
and ensure a single source of truth for Result file scanning and column parsing.

All table display paths (local + migrations) must go through this for consistency.

=cut

sub new {
    my ($class, %args) = @_;
    return bless { logging => $args{logging} }, $class;
}

sub logging {
    my ($self) = @_;
    return $self->{logging} if $self->{logging};
    # Fallback
    require Comserv::Util::Logging;
    return Comserv::Util::Logging->new();
}

# Get all Result files for a database (ency / forager)
sub get_all_result_files {
    my ($self, $database, $c) = @_;
    my @result_files = ();
    my $base_path = $self->_get_schema_base($c);

    if (lc($database || '') eq 'ency') {
        my $result_dir = File::Spec->catdir($base_path, 'Ency', 'Result');
        @result_files = $self->scan_result_directory_recursive($result_dir, '');
    } elsif (lc($database || '') eq 'forager') {
        my $result_dir = File::Spec->catdir($base_path, 'Forager', 'Result');
        @result_files = $self->scan_result_directory_recursive($result_dir, '');
    }
    return @result_files;
}

# Robust way to locate the Result Schema base dir.
# Prefers $c->path_to when a Catalyst context is available (most page flows).
# Falls back to $INC or __FILE__ calculation so calls without $c still work.
sub _get_schema_base {
    my ($self, $c) = @_;

    if ($c && $c->can('path_to')) {
        my $p = $c->path_to('lib', 'Comserv', 'Model', 'Schema');
        return ref($p) && $p->can('stringify') ? $p->stringify : "$p";
    }

    if (my $inc = $INC{'Comserv.pm'}) {
        my $lib = dirname($inc);
        return File::Spec->catdir($lib, 'Comserv', 'Model', 'Schema');
    }

    # Fallback: from this file (lib/Comserv/Util/Schema/ResultParser.pm) go up to lib/
    my $d = __FILE__;
    $d = dirname($d) for (1..4);   # Util/Schema -> Util -> Comserv -> lib
    return File::Spec->catdir($d, 'Comserv', 'Model', 'Schema');
}

sub scan_result_directory_recursive {
    my ($self, $dir_path, $prefix) = @_;
    my @files = ();
    if (opendir(my $dh, $dir_path)) {
        while (my $file = readdir($dh)) {
            next if $file =~ /^\.\.?$/;
            my $full_path = File::Spec->catfile($dir_path, $file);
            if (-d $full_path) {
                push @files, $self->scan_result_directory_recursive($full_path, $prefix . $file . '/');
            } elsif ($file =~ /\.pm$/) {
                my $name = $file;
                $name =~ s/\.pm$//;
                push @files, {
                    name => $prefix . $name,
                    path => $full_path,
                    last_modified => (stat($full_path))[9],
                };
            }
        }
        closedir($dh);
    }
    return @files;
}

sub extract_table_name_from_result_file {
    my ($self, $file_path) = @_;
    return unless -f $file_path;
    my $content = do { local $/; open my $fh, '<', $file_path or return; <$fh> };

    # Try multiple patterns to handle different formatting
    if ($content =~ /__PACKAGE__->table\s*\(\s*['"]([^'"]+)['"]\s*\)/s) {
        return $1;
    }
    # Multi-line or with extra whitespace
    if ($content =~ /__PACKAGE__->table\s*\(\s*['"]([^'"]+)['"]/s) {
        return $1;
    }
    # Fallback: filename without .pm
    my ($name) = $file_path =~ m{([^/\\]+)\.pm$};
    return $name;
}

sub build_result_table_mapping {
    my ($self, $database, $c) = @_;
    my %mapping = ();
    my @result_files = $self->get_all_result_files($database, $c);
    foreach my $rf (@result_files) {
        my $table_name = $self->extract_table_name_from_result_file($rf->{path}) || $rf->{name};
        if ($table_name) {
            $mapping{lc($table_name)} = {
                result_name => $rf->{name},
                result_path => $rf->{path},
                last_modified => $rf->{last_modified},
            };
        }
    }
    return \%mapping;
}

sub get_result_file_path {
    my ($self, $table_name, $database, $c) = @_;
    my $mapping = $self->build_result_table_mapping($database, $c);
    my $info = $mapping->{lc($table_name)};
    return $info ? $info->{result_path} : undef;
}

# Parse full schema from a Result .pm file (columns + pk + uniques + rels)
sub get_result_file_schema {
    my ($self, $file_path) = @_;
    my $schema_info = {
        file_path => $file_path,
        columns => {},
        primary_keys => [],
        unique_constraints => [],
        relationships => {},
        table_name => undef,
        raw_package_calls => [],
    };
    return $schema_info unless -f $file_path;

    try {
        open my $fh, '<', $file_path or die "open: $!";
        local $/; my $content = <$fh>; close $fh;

        if ($content =~ /__PACKAGE__->table\s*\(\s*['"]([^'"]+)['"]\s*\)/s) {
            $schema_info->{table_name} = $1;
        }

        while ($content =~ /(__PACKAGE__->(\w+)\s*\((.*?)\)\s*;)/gs) {
            push @{$schema_info->{raw_package_calls}}, { full => $1, method => $2, args => $3 };
        }

        my $add_columns_content = $self->_extract_balanced_parens($content, '__PACKAGE__->add_columns');
        if ($add_columns_content) {
            $schema_info->{columns} = $self->parse_result_file_columns($add_columns_content);
        }

        if ($content =~ /__PACKAGE__->set_primary_key\s*\((.*?)\)/s) {
            my $pk_text = $1;
            $pk_text =~ s/['"\s]//g;
            @{$schema_info->{primary_keys}} = split /,/, $pk_text;
        }

        while ($content =~ /__PACKAGE__->add_unique_constraint\s*\(\s*(?:['"]([^'"]+)['"]\s*=>\s*)?\[(.*?)\]\s*\)/gs) {
            my $name = $1 || 'unnamed';
            my $cols = $2; $cols =~ s/['"\s]//g;
            push @{$schema_info->{unique_constraints}}, { name => $name, columns => [split /,/, $cols] };
        }

        while ($content =~ /__PACKAGE__->(belongs_to|has_many|has_one|might_have)\s*\(\s*['"]?(\w+)['"]?\s*=>\s*['"]?([^'",\s\)]+)['"]?\s*(?:,\s*(?:['"]?(\w+)['"]?|\{(.*?)\}))?/gs) {
            my ($type, $accessor, $class, $fk) = ($1, $2, $3, $4);
            $schema_info->{relationships}->{$accessor} = {
                type => $type, class => $class, column => $fk || $accessor
            };
        }
    } catch {
        # log if possible
    };
    return $schema_info;
}

# The robust brace-walking parser (consolidated from previous fixes)
sub parse_result_file_columns {
    my ($self, $text) = @_;
    my $columns = {};
    while ($text =~ /(?:['"](\w+)['"]|(\w+))\s*=>\s*\{/g) {
        my $col_name = $1 || $2;
        my $start = pos($text);
        my $depth = 1; my $i = $start;
        while ($i < length($text) && $depth > 0) {
            my $ch = substr($text, $i, 1);
            $depth++ if $ch eq '{';
            $depth-- if $ch eq '}';
            $i++;
        }
        my $def = substr($text, $start, $i - $start - 1);
        pos($text) = $i;

        my $info = {};
        pos($def) = 0 if defined pos($def);
        while ($def =~ /(\w+)\s*=>\s*/g) {
            my $attr = $1; my $val;
            if ($def =~ /\G\s*\\?['"]([^'"]*)['"]/gc) { $val = $1; }
            elsif ($def =~ /\G\s*(\d+)/gc) { $val = $1 + 0; }
            elsif ($def =~ /\G\s*undef\b/gc) { $val = undef; }
            elsif ($def =~ /\G\s*\\(['"])([^'"]*)\1/gc) { $val = $2; }
            elsif ($def =~ /\G\s*\{/gc) {
                my $hstart = pos($def)-1; my $hdepth=1; my $j=pos($def);
                while ($j < length($def) && $hdepth>0) { my $ch=substr($def,$j,1); $hdepth++ if $ch eq '{'; $hdepth-- if $ch eq '}'; $j++; }
                $val = substr($def, $hstart, $j-$hstart);
                pos($def) = $j;
            } else {
                if ($def =~ /\G\s*(\w+)/gc) { $val = $1; }
            }
            if (defined $val || !exists $info->{$attr}) {
                $info->{$attr} = $val;
            }
        }
        $columns->{$col_name} = $info;
    }

    if (scalar(keys %$columns) == 0) {
        # simple fallback
        while ($text =~ /(\w+)\s*=>\s*\{([^}]+)\}/g) {
            my ($cn, $cd) = ($1, $2);
            my $ci = {};
            while ($cd =~ /(\w+)\s*=>\s*['"]?([^'",\s\}]+)['"]?/g) { $ci->{$1} = $2; }
            $columns->{$cn} = $ci;
        }
    }
    return $columns;
}

# Robust extractor for __PACKAGE__->foo( ... ) balancing parens, to avoid brittle (.*?) regex cutting off last columns
sub _extract_balanced_parens {
    my ($self, $content, $prefix) = @_;
    my $re = quotemeta($prefix) . '\s*\(';
    if ($content =~ /$re/g) {
        my $start = pos($content);
        my $depth = 1;
        my $i = $start;
        while ($i < length($content) && $depth > 0) {
            my $ch = substr($content, $i, 1);
            $depth++ if $ch eq '(';
            $depth-- if $ch eq ')';
            $i++;
        }
        if ($depth == 0) {
            my $inside = substr($content, $start, $i - $start - 1);
            pos($content) = $i;
            # skip optional ;
            if (substr($content, $i, 1) eq ';') { pos($content) = $i+1; }
            return $inside;
        }
    }
    return '';
}

1;