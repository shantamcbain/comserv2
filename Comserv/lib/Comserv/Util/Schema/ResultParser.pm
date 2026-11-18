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

# Get all Result files for a database (ency / forager / accounting=PG clone-target)
sub get_all_result_files {
    my ($self, $database, $c) = @_;
    my @result_files = ();
    my $base_path = $self->_get_schema_base($c);
    my $db = lc($database || '');

    if ($db eq 'ency') {
        my $result_dir = File::Spec->catdir($base_path, 'Ency', 'Result');
        @result_files = $self->scan_result_directory_recursive($result_dir, '');
    } elsif ($db eq 'forager') {
        my $result_dir = File::Spec->catdir($base_path, 'Forager', 'Result');
        @result_files = $self->scan_result_directory_recursive($result_dir, '');
    } elsif ($db eq 'accounting' || $db eq 'pg' || $db eq 'postgresql' || $db eq 'postgres') {
        # Schema::Accounting::Result::* — PostgreSQL clone-target (not Maria Ency)
        my $result_dir = File::Spec->catdir($base_path, 'Accounting', 'Result');
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
            my $cols = $self->_parse_perl_list($2);
            push @{$schema_info->{unique_constraints}}, { name => $name, columns => $cols };
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

# Parse a single "{ ... }" block's inner content into a hashref.
# Walks the block character-by-character, balancing [] and {} so array and
# nested-hash values (e.g. enum `extra => { list => [ 'tt', 'md' ] }`) are
# captured verbatim instead of being mis-parsed as an opaque string.

# Parse the interior of a Perl list: [ 'a', 'b' ], [10, 2],
# [qw/calm moderate/], [qw(role module)]. Used for enum lists, decimal
# size arrays, and unique-constraint column lists.
sub _parse_perl_list {
    my ($self, $inner) = @_;
    $inner = '' unless defined $inner;
    $inner =~ s/^\s+|\s+$//g;
    my @items;
    if ($inner =~ /^\s*qw\s*(\S)(.*)\S\s*$/s) {
        my $body = $2 // '';
        $body =~ s/^\s+|\s+$//g;
        for my $tok (split /\s+/, $body) {
            $tok =~ s/^['"]|['"]$//g;
            push @items, $tok if length $tok;
        }
        return \@items;
    }
    while ($inner =~ /(['"])\s*((?:(?!\1).)*)\s*\1|([+-]?\d+(?:\.\d+)?)/g) {
        push @items, defined $3 ? $3 + 0 : $2;
    }
    return \@items;
}

sub _parse_result_inner_hash {
    my ($self, $block) = @_;
    $block = '' unless defined $block;
    my $info = {};

    my $i = 0;
    my $len = length($block);

    while ($i < $len) {
        # Skip whitespace
        $i++ while $i < $len && substr($block, $i, 1) =~ /\s/;

        # Read attribute name up to '=>'
        my $name = '';
        while ($i < $len && substr($block, $i, 1) ne '=' && substr($block, $i, 1) =~ /\S/) {
            $name .= substr($block, $i, 1); $i++;
        }
        $name =~ s/\s+$//;
        last unless length $name;

        # Skip past '=>'
        $i++ while $i < $len && substr($block, $i, 1) ne '>';
        $i++; # consume '>'

        # Skip whitespace
        $i++ while $i < $len && substr($block, $i, 1) =~ /\s/;
        next if $i >= $len;

        my $ch = substr($block, $i, 1);

        if ($ch eq '[') {
            my $depth = 1; my $j = $i + 1;
            while ($j < $len && $depth > 0) {
                my $c = substr($block, $j, 1);
                $depth++ if $c eq '[';
                $depth-- if $c eq ']';
                $j++;
            }
            my $inner = substr($block, $i + 1, $j - $i - 2);
            $info->{$name} = $self->_parse_perl_list($inner);
            $i = $j;
        }
        elsif ($ch eq '{') {
            my $depth = 1; my $j = $i + 1;
            while ($j < $len && $depth > 0) {
                my $c = substr($block, $j, 1);
                $depth++ if $c eq '{';
                $depth-- if $c eq '}';
                $j++;
            }
            my $inner = substr($block, $i + 1, $j - $i - 2);
            $info->{$name} = $self->_parse_result_inner_hash($inner);
            $i = $j;
        }
        elsif ($ch eq "'" || $ch eq '"') {
            my $q = $ch; my $j = $i + 1; my $val = '';
            while ($j < $len) {
                my $c = substr($block, $j, 1);
                last if $c eq $q;
                $val .= $c; $j++;
            }
            $info->{$name} = $val;
            $i = $j + 1;
        }
        else {
            # bareword / number / undef
            my $val = '';
            while ($i < $len && substr($block, $i, 1) !~ /[,\s]/) {
                $val .= substr($block, $i, 1); $i++;
            }
            if ($val eq 'undef') { $info->{$name} = undef; }
            elsif ($val =~ /^\d+$/) { $info->{$name} = $val + 0; }
            else { $info->{$name} = $val; }
        }

        # Skip comma / separator
        $i++ while $i < $len && substr($block, $i, 1) =~ /[,\s]/;
    }

    return $info;
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
            # Scalar-ref literal SQL, e.g. default_value => \'CURRENT_TIMESTAMP'.
            # Must be tested BEFORE the plain-quote branch: the leading backslash
            # makes /\G\s*(['"])/ fail, so these previously fell through to the
            # bareword branch and parsed as undef -- which made every
            # set_on_create timestamp read as a permanent "Update needed".
            if ($def =~ /\G\s*\\\s*(['"])((?:(?!\1).)*)\1/gc) { $val = $2; }
            elsif ($def =~ /\G\s*(['"])((?:(?!\1).)*)\1/gc) { $val = $2; }
            elsif ($def =~ /\G\s*(\d+)/gc) { $val = $1 + 0; }
            elsif ($def =~ /\G\s*undef\b/gc) { $val = undef; }
            # Array ref, e.g. size => [10, 2] or [ 'tt', 'md' ]. Without this
            # branch the value fell through to the bareword branch, which cannot
            # match '[', so every decimal's size parsed as undef: the schema
            # compare panel showed no size on the Result side and "Add column"
            # built DECIMAL with no scale (decimal(10,0)).
            elsif ($def =~ /\G\s*\[/gc) {
                my $astart = pos($def) - 1; my $adepth = 1; my $j = pos($def);
                while ($j < length($def) && $adepth > 0) {
                    my $ch = substr($def, $j, 1);
                    $adepth++ if $ch eq '[';
                    $adepth-- if $ch eq ']';
                    $j++;
                }
                my $inner = substr($def, $astart + 1, $j - $astart - 2);
                $val = $self->_parse_perl_list($inner);
                pos($def) = $j;
            }
            elsif ($def =~ /\G\s*\{/gc) {
                my $hstart = pos($def)-1; my $hdepth=1; my $j=pos($def);
                while ($j < length($def) && $hdepth>0) { my $ch=substr($def,$j,1); $hdepth++ if $ch eq '{'; $hdepth-- if $ch eq '}'; $j++; }
                my $block = substr($def, $hstart+1, $j-$hstart-2);
                $val = $self->_parse_result_inner_hash($block);
                pos($def) = $j;
            }
            elsif ($def =~ /\G\s*\[/gc) {
                # Arrayref literals (size => [10, 4], extra => [qw(a b)]). Without
                # this branch the bareword fallback fails and the attribute lands
                # as undef -- every decimal column then reported a blank size, and
                # a table sync issued "MODIFY col decimal" (i.e. decimal(10,0)).
                my $astart = pos($def)-1; my $adepth = 1; my $j = pos($def);
                while ($j < length($def) && $adepth > 0) {
                    my $ch = substr($def, $j, 1);
                    $adepth++ if $ch eq '[';
                    $adepth-- if $ch eq ']';
                    $j++;
                }
                my $inner = substr($def, $astart+1, $j-$astart-2);
                my @items;
                while ($inner =~ /(-?\d+(?:\.\d+)?)/g) { push @items, $1 + 0; }
                $val = \@items;
                pos($def) = $j;
            } else {
                if ($def =~ /\G\s*(\w+(?:\([^)]*\))?)/gc) { $val = $1; }
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


# Flatten one parsed Result-file column into UI-safe scalar attributes.
# Template Toolkit cannot print ARRAY/HASH refs (those cells render empty),
# and schema_compare_table previously hard-coded Result extra/comment to ''.
#
# Returns:
#   name, data_type,
#   size            -- '(10,2)' / '(50)' / ''  (empty when undeclared; for comparison)
#   is_nullable     -- 'YES' / 'NO' / undef     (undef = not declared; do not compare)
#   nullable        -- 'YES' / 'NO' / '--'      (display; em-dash when undeclared)
#   default_value   -- scalar or undef
#   default_val     -- display ('NULL' when undef)
#   extra           -- 'auto_increment', 'enum(a,b)', 'unsigned', ... never a ref
#   comment         -- comment // docs // documentation, or ''
sub format_column_for_display {
    my ($self, $col, $name) = @_;
    $col = {} unless ref($col) eq 'HASH';

    my $dt = $col->{data_type} // $col->{type} // 'varchar';

    my $sz_raw;
    my $size_in = $col->{size};
    $size_in = $col->{data_length} if !defined $size_in || $size_in eq '';
    if (ref($size_in) eq 'ARRAY' && @{$size_in}) {
        $sz_raw = join(',', @{$size_in});
    }
    elsif (defined $size_in && !ref($size_in) && $size_in ne '') {
        $sz_raw = $size_in;
    }
    my $size = defined $sz_raw ? '(' . $sz_raw . ')' : '';

    my $nullable;
    if (defined $col->{is_nullable} && $col->{is_nullable} ne '') {
        $nullable = ($col->{is_nullable} =~ /^(0|no|false)$/i) ? 'NO' : 'YES';
    }
    elsif ($col->{is_auto_increment}) {
        $nullable = 'NO';
    }
    else {
        $nullable = undef;
    }

    my $default = $col->{default_value};
    $default = $$default if ref($default) eq 'SCALAR';
    $default = undef if ref($default);

    my @extra;
    push @extra, 'auto_increment' if $col->{is_auto_increment};
    my $ex = $col->{extra};
    if (ref($ex) eq 'HASH') {
        if (ref($ex->{list}) eq 'ARRAY' && @{$ex->{list}}) {
            push @extra, 'enum(' . join(',', @{ $ex->{list} }) . ')';
        }
        for my $k (sort keys %$ex) {
            next if $k eq 'list';
            my $v = $ex->{$k};
            next if ref $v;
            next unless defined $v && $v ne '';
            if ($v eq '1' || lc($v) eq 'true') {
                push @extra, $k;
            }
            else {
                push @extra, "$k=$v";
            }
        }
    }
    elsif (defined $ex && !ref($ex) && $ex ne '') {
        push @extra, $ex;
    }

    my $comment = $col->{comment} // $col->{docs} // $col->{documentation} // '';
    $comment = '' if ref $comment;

    return {
        name          => $name // '',
        data_type     => $dt,
        size          => $size,
        is_nullable   => $nullable,
        nullable      => defined $nullable ? $nullable : "\x{2014}",
        default_value => $default,
        default_val   => defined $default ? $default : 'NULL',
        extra         => join(' ', @extra),
        comment       => $comment,
        is_auto_increment => $col->{is_auto_increment} ? 1 : 0,
        is_primary_key    => $col->{is_primary_key} ? 1 : 0,
        docs              => $comment,
    };
}

# Parse a Result file and return an ordered, TT-safe field list for table previews.
sub preview_fields {
    my ($self, $path) = @_;
    my $empty = { columns => {}, fields => [], primary_keys => [], field_count => 0, table_name => undef };
    return $empty unless $path && -f $path;
    my $schema = eval { $self->get_result_file_schema($path) };
    return $empty unless $schema && ref($schema->{columns}) eq 'HASH';

    my @pks = @{ $schema->{primary_keys} || [] };
    my %pk  = map { $_ => 1 } @pks;
    my @fields;
    for my $cname (sort keys %{ $schema->{columns} }) {
        my $cinfo = $schema->{columns}{$cname} || {};
        $cinfo->{is_primary_key} = 1 if $pk{$cname};
        my $disp = $self->format_column_for_display($cinfo, $cname);
        $disp->{is_primary_key} = $pk{$cname} ? 1 : 0;
        push @fields, $disp;
    }
    return {
        columns            => $schema->{columns},
        fields             => \@fields,
        primary_keys       => \@pks,
        unique_constraints => $schema->{unique_constraints} || [],
        field_count        => scalar(@fields),
        table_name         => $schema->{table_name},
    };
}

1;
