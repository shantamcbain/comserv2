# AI-REMINDER: keep file < 1 500 lines; follow .ai-policy.md
package Comserv::Util::Schema::Equivalence;

use strict;
use warnings;

=head1 NAME

Comserv::Util::Schema::Equivalence - Result-vs-live field and table comparison

Single place for the normalisation that stops false positives (int vs integer,
int(11) display width, NULL vs a missing default, name case, unsigned/charset
noise, CURRENT_TIMESTAMP spellings) while still reporting real drift.

Controller/Admin/SchemaComparison delegates here so the compare UI and the
tables-list badges cannot disagree. Pure data in, data out — no DBI, no
templates.

=cut

sub new {
    my ($class, %args) = @_;
    return bless { %args }, $class;
}

# --- public class-or-instance methods (the first arg is ignored if it's
#     a class name or object, so SchemaComparison can delegate with shift) ---

sub normalize_data_type {
    my ($self, $data_type) = @_;
    $data_type = $_[0] if !ref($self) && $self ne __PACKAGE__ && @_ == 1;
    return '' unless defined $data_type;
    $data_type = lc($data_type);
    # Pull a leading enum(...) out before stripping parens so callers can
    # still see it via enum_list(); the mapped type becomes 'enum'.
    if ($data_type =~ /^enum\s*\(/) {
        return 'enum';
    }
    $data_type =~ s/\([^)]*\)//g;
    $data_type =~ s/^\s+|\s+$//g;
    $data_type =~ s/\s+(unsigned|signed|zerofill|binary)//g;
    $data_type =~ s/\s+character\s+set\s+\S+//g;
    $data_type =~ s/\s+charset\s+\S+//g;
    $data_type =~ s/\s+collate\s+\S+//g;

    my %mapping = (
        'int' => 'integer', 'int4' => 'integer', 'integer' => 'integer',
        'varchar' => 'varchar', 'character varying' => 'varchar',
        'text' => 'text', 'longtext' => 'text', 'mediumtext' => 'text', 'tinytext' => 'text',
        'tinyint' => 'boolean', 'bool' => 'boolean', 'boolean' => 'boolean',
        'datetime' => 'datetime', 'timestamp' => 'timestamp', 'json' => 'json',
        'enum' => 'enum',
    );
    return $mapping{$data_type} || $data_type;
}

sub is_width_only_type {
    my ($self, $normalized_type) = @_;
    $normalized_type = $_[0] if !ref($self) && $self ne __PACKAGE__ && @_ == 1;
    return 0 unless defined $normalized_type;
    return $normalized_type =~ /^(integer|boolean|bigint|smallint|mediumint)$/ ? 1 : 0;
}

# Alias used by the controller's historical name.
sub _is_width_only_type { goto &is_width_only_type; }

sub normalize_nullable {
    my ($self, $value) = @_;
    $value = $_[0] if !ref($self) && $self ne __PACKAGE__ && @_ == 1;
    return undef unless defined $value && $value ne '';
    return 'NO'  if $value =~ /^(0|no|false)$/i;
    return 'YES' if $value =~ /^(1|yes|true)$/i;
    return uc($value);
}

sub normalize_default {
    my ($self, $value) = @_;
    $value = $_[0] if !ref($self) && $self ne __PACKAGE__ && @_ == 1;
    $value = $$value if ref($value) eq 'SCALAR';
    return 'NULL' if !defined $value || ( !ref($value) && ( $value eq '' || uc($value) eq 'NULL' ) );
    $value = "$value";
    $value =~ s/^\s+|\s+$//g;
    $value =~ s/\s*ON\s+UPDATE\s+CURRENT_TIMESTAMP\s*(\(\))?//i;
    $value =~ s/^'(.*)'$/$1/s;
    $value =~ s/^"(.*)"$/$1/s;
    $value =~ s/\(\)$//;
    $value = uc($value) if $value =~ /^current_timestamp/i;
    $value = 'NULL' if $value eq '';
    return $value;
}

# Returns a comparable size string (no parens). Width-only types return ''.
# $role is 'result' or 'table' — Result varchar with no size defaults to
# DBIx's 255 so "varchar" vs "varchar(255)" is not a false positive.
sub normalize_size {
    my ($self, $size, $norm_type, $role) = @_;
    if (!ref($self) && $self ne __PACKAGE__) {
        # called as Equivalence::normalize_size($size, $type, $role)
        ($size, $norm_type, $role) = @_;
    }
    my $s = lc(defined $size && !ref($size) ? $size : '');
    if (ref($size) eq 'ARRAY' && @$size) {
        $s = lc(join(',', @$size));
    }
    $s =~ s/[()\s]//g;
    return '' if is_width_only_type(__PACKAGE__, $norm_type);
    if ($s eq '' && ($role // '') eq 'result' && ($norm_type // '') eq 'varchar') {
        return '255';
    }
    return $s;
}

sub enum_list {
    my ($self, $col) = @_;
    $col = $_[0] if !ref($self) && $self ne __PACKAGE__ && @_ == 1;
    return undef unless $col && ref($col) eq 'HASH';
    my $from = sub {
        my ($txt) = @_;
        return undef unless defined $txt && $txt =~ /enum\s*\((.*)\)/is;
        my $inner = $1;
        my @items;
        while ($inner =~ /['"]([^'"]*)['"]|([^,\s]+)/g) {
            my $v = defined $1 ? $1 : $2;
            next unless defined $v;
            $v =~ s/^\s+|\s+$//g;
            push @items, lc($v) if length $v;
        }
        return @items ? \@items : undef;
    };
    my $list = $from->($col->{data_type} // '');
    return $list if $list;
    $list = $from->($col->{extra} // '') unless ref($col->{extra});
    return $list if $list;
    if (ref($col->{extra}) eq 'HASH' && ref($col->{extra}{list}) eq 'ARRAY') {
        return [ map { lc("$_") } @{ $col->{extra}{list} } ];
    }
    return undef;
}

# Strip noise (unsigned, charset, collate, ON UPDATE, auto_increment which is
# tracked separately) so leftover Extra text can be compared.
sub normalize_extra {
    my ($self, $col) = @_;
    $col = $_[0] if !ref($self) && $self ne __PACKAGE__ && @_ == 1;
    $col = {} unless $col && ref($col) eq 'HASH';
    my $e = lc($col->{extra} // '');
    $e = '' if ref($col->{extra});    # hash form is handled as enum_list
    my $ai = $col->{is_auto_increment} ? 1 : 0;
    $ai = 1 if $e =~ /\bauto_increment\b/;
    $e =~ s/\bauto_increment\b//g;
    $e =~ s/\bon\s+update\s+current_timestamp(\(\))?//g;
    $e =~ s/\bunsigned\b//g;
    $e =~ s/\bzerofill\b//g;
    $e =~ s/\bsigned\b//g;
    $e =~ s/\bbinary\b//g;
    $e =~ s/character\s+set\s+\S+//g;
    $e =~ s/\bcharset\s+\S+//g;
    $e =~ s/\bcollate\s+\S+//g;
    $e =~ s/\benum\s*\([^)]*\)//g;
    $e =~ s/\s+/ /g;
    $e =~ s/^\s+|\s+$//g;
    return { extra => $e, auto_increment => $ai ? 1 : 0 };
}

=head2 fields_equivalent($db_col, $result_col)

True when the two column hashes mean the same thing after normalisation.
An absent Result C<is_nullable> is unknown and is not compared. Returns
false if either side is missing (a presence difference).

=cut

sub fields_equivalent {
    my ($self, $d, $r) = @_;
    # Support class-method, instance, or bare call.
    if (@_ == 2 && !(_looks_like_invocant($self))) {
        ($d, $r) = ($self, $d);
    }
    elsif (@_ == 3 && _looks_like_invocant($self)) {
        # normal
    }
    return 0 unless $d && $r && ref($d) eq 'HASH' && ref($r) eq 'HASH';
    return @{ _column_diffs($d, $r) } ? 0 : 1;
}

# Historical name used by SchemaComparison and its tests.
sub _fields_equivalent { goto &fields_equivalent; }

sub _looks_like_invocant {
    my ($x) = @_;
    return 1 if ref($x) && eval { $x->isa(__PACKAGE__) };
    return 1 if !ref($x) && defined $x && $x eq __PACKAGE__;
    return 0;
}

# Returns a list of { attribute, table_value, result_value } hashes.
sub _column_diffs {
    my ($d, $r) = @_;
    my @diffs;

    my $d_enum = enum_list(__PACKAGE__, $d);
    my $r_enum = enum_list(__PACKAGE__, $r);
    my $d_type = normalize_data_type(__PACKAGE__, $d->{data_type} // $d->{type} // '');
    my $r_type = normalize_data_type(__PACKAGE__, $r->{data_type} // $r->{type} // '');
    $d_type = 'enum' if $d_enum;
    $r_type = 'enum' if $r_enum;

    if ($d_type ne $r_type) {
        # varchar+enum-list vs enum is already folded to enum on both sides
        # when a list is present. A remaining type mismatch is genuine.
        push @diffs, {
            attribute    => 'type',
            table_value  => $d->{data_type} // '',
            result_value => $r->{data_type} // '',
        };
    }
    elsif ($d_enum || $r_enum) {
        # A Result that only says data_type => 'enum' and never lists the
        # values is undeclared, like an omitted is_nullable: do not flag.
        # When the Result does list values, a mismatch is genuine.
        if ($r_enum) {
            my $ds = join(',', @{ $d_enum || [] });
            my $rs = join(',', @$r_enum);
            if ($ds ne $rs) {
                push @diffs, {
                    attribute    => 'extra',
                    table_value  => $ds ne '' ? "enum($ds)" : '',
                    result_value => "enum($rs)",
                };
            }
        }
    }

    # Enum values live in the type/extra list, not in size. A Result that
    # declares varchar + extra => { list } still has a varchar size that
    # must not be compared against the live enum, which has no size.
    my $d_size = normalize_size(__PACKAGE__, $d->{size}, $d_type, 'table');
    my $r_size = normalize_size(__PACKAGE__, $r->{size}, $r_type, 'result');
    if ($d_type eq 'enum' && $r_type eq 'enum') {
        $d_size = '';
        $r_size = '';
    }
    if ($d_size ne $r_size) {
        push @diffs, {
            attribute    => 'size',
            table_value  => $d->{size} // '',
            result_value => $r->{size} // '',
        };
    }

    my $r_null = normalize_nullable(__PACKAGE__, $r->{is_nullable});
    if (defined $r_null) {
        my $d_null = normalize_nullable(__PACKAGE__, $d->{is_nullable});
        $d_null = '' unless defined $d_null;
        if (lc($d_null) ne lc($r_null)) {
            push @diffs, {
                attribute    => 'nullable',
                table_value  => $d_null,
                result_value => $r_null,
            };
        }
    }

    my $d_def = normalize_default(__PACKAGE__, $d->{default_value});
    my $r_def = normalize_default(__PACKAGE__, $r->{default_value});
    # Numeric 0 vs '0' vs 0.0
    if ($d_def =~ /^-?\d+(?:\.\d+)?$/ && $r_def =~ /^-?\d+(?:\.\d+)?$/) {
        if ($d_def + 0 != $r_def + 0) {
            push @diffs, {
                attribute    => 'default',
                table_value  => $d_def,
                result_value => $r_def,
            };
        }
    }
    elsif (lc($d_def) ne lc($r_def)) {
        push @diffs, {
            attribute    => 'default',
            table_value  => $d_def,
            result_value => $r_def,
        };
    }

    my $d_ex = normalize_extra(__PACKAGE__, $d);
    my $r_ex = normalize_extra(__PACKAGE__, $r);
    if ($d_ex->{auto_increment} != $r_ex->{auto_increment}) {
        push @diffs, {
            attribute    => 'extra',
            table_value  => $d_ex->{auto_increment} ? 'auto_increment' : '',
            result_value => $r_ex->{auto_increment} ? 'auto_increment' : '',
        };
    }
    elsif (($d_ex->{extra} // '') ne ($r_ex->{extra} // '')) {
        push @diffs, {
            attribute    => 'extra',
            table_value  => $d_ex->{extra},
            result_value => $r_ex->{extra},
        };
    }

    return \@diffs;
}

# Literal comparison used only to measure false positives removed.
sub fields_equivalent_naive {
    my ($self, $d, $r) = @_;
    if (@_ == 2 && !_looks_like_invocant($self)) {
        ($d, $r) = ($self, $d);
    }
    return 0 unless $d && $r;
    for my $k (qw(data_type size is_nullable default_value extra)) {
        my $dv = $d->{$k} // '';
        my $rv = $r->{$k} // '';
        $dv = join(',', @$dv) if ref($dv) eq 'ARRAY';
        $rv = join(',', @$rv) if ref($rv) eq 'ARRAY';
        return 0 if "$dv" ne "$rv";
    }
    return 1;
}

=head2 compare_table(%args)

Compare one live table with one Result file.

    has_table, has_result
    table_name
    db_columns      — { lc(name) => col hash }
    result_columns  — { lc(name) => col hash }  (preview_fields entries are fine)
    db_primary_keys, result_primary_keys — arrayrefs of names
    db_uniques, result_uniques — arrayrefs of { name, columns => [] }
    naive — if true, use literal comparison (for measuring false positives)

Returns { has_problem, issue_count, issues => [ ... ], naive_issue_count? }.

=cut

sub compare_table {
    my ($self, %arg) = @_;
    if (@_ >= 1 && !_looks_like_invocant($self) && ref($self) eq 'HASH') {
        %arg = ($self, @_[1..$#_]);
    }
    elsif (@_ >= 2 && ref($self) eq 'HASH' && !%arg) {
        %arg = %$self;
    }
    # When called as Equivalence->compare_table(%arg), $self is the class.
    if (@_ % 2 == 1 && _looks_like_invocant($self)) {
        # already got %arg from the rest
    }
    elsif (@_ % 2 == 0 && !_looks_like_invocant($_[0])) {
        %arg = @_;
    }

    my $tname = $arg{table_name} // '';
    my @issues;
    my $has_table  = $arg{has_table}  ? 1 : 0;
    my $has_result = $arg{has_result} ? 1 : 0;

    if ($has_table && !$has_result) {
        push @issues, _issue($tname, '', 'missing_result', 'present', 'absent',
            "Live table has no Result file");
        return _pack(\@issues);
    }
    if ($has_result && !$has_table) {
        push @issues, _issue($tname, '', 'missing_table', 'absent', 'present',
            "Result file has no live table");
        return _pack(\@issues);
    }

    my $db_cols = $arg{db_columns} || {};
    my $rs_cols = $arg{result_columns} || {};
    # Accept an array of preview fields too.
    if (ref($rs_cols) eq 'ARRAY') {
        my %h;
        for my $f (@$rs_cols) {
            next unless $f && $f->{name};
            $h{ lc($f->{name}) } = $f;
        }
        $rs_cols = \%h;
    }
    if (ref($db_cols) eq 'ARRAY') {
        my %h;
        for my $f (@$db_cols) {
            next unless $f && $f->{name};
            $h{ lc($f->{name}) } = $f;
        }
        $db_cols = \%h;
    }

    my %all = map { $_ => 1 } (keys %$db_cols, keys %$rs_cols);
    my $use_naive = $arg{naive} ? 1 : 0;

    for my $cname (sort keys %all) {
        my $d = $db_cols->{$cname};
        my $r = $rs_cols->{$cname};
        if ($d && !$r) {
            push @issues, _issue($tname, $d->{name} // $cname, 'missing_in_result',
                'present', 'absent',
                "Column exists in the live table but not in the Result file");
            next;
        }
        if ($r && !$d) {
            push @issues, _issue($tname, $r->{name} // $cname, 'missing_in_table',
                'absent', 'present',
                "Column exists in the Result file but not in the live table");
            next;
        }
        if ($use_naive) {
            unless (fields_equivalent_naive(__PACKAGE__, $d, $r)) {
                push @issues, _issue($tname, $r->{name} // $cname, 'type',
                    $d->{data_type} // '', $r->{data_type} // '',
                    "Naive (literal) mismatch");
            }
            next;
        }
        my $diffs = _column_diffs($d, $r);
        for my $diff (@$diffs) {
            push @issues, _issue(
                $tname,
                $r->{name} // $d->{name} // $cname,
                $diff->{attribute},
                $diff->{table_value},
                $diff->{result_value},
                _msg($diff),
            );
        }
    }

    # Keys — only when the Result side actually declares them.
    my @rpk = _lc_list($arg{result_primary_keys});
    my @dpk = _lc_list($arg{db_primary_keys});
    if (@rpk) {
        my $rs = join(',', @rpk);
        my $ds = join(',', @dpk);
        if ($rs ne $ds) {
            push @issues, _issue($tname, join(',', @rpk), 'primary_key',
                join(',', @dpk) || '(none)',
                join(',', @rpk),
                "Primary key differs");
        }
    }

    my @runq = @{ $arg{result_uniques} || [] };
    my @dunq = @{ $arg{db_uniques} || [] };
    if (@runq) {
        my %db_sets = map { _cols_key($_->{columns}) => ($_->{name} // '') } @dunq;
        # Also treat the PK as a unique set the Result unique can match.
        $db_sets{ join(',', @dpk) } = 'PRIMARY' if @dpk;
        for my $u (@runq) {
            my $key = _cols_key($u->{columns});
            next if $key eq '';
            unless (exists $db_sets{$key}) {
                push @issues, _issue($tname, $u->{name} // $key, 'unique',
                    '(none)',
                    join(',', @{ $u->{columns} || [] }),
                    "Result unique constraint not present on the live table");
            }
        }
    }

    return _pack(\@issues);
}

sub _cols_key {
    my ($cols) = @_;
    return '' unless $cols && @$cols;
    return join(',', map { lc($_) } @$cols);
}

sub _lc_list {
    my ($a) = @_;
    return () unless $a && ref($a) eq 'ARRAY';
    return map { lc($_) } @$a;
}

sub _msg {
    my ($diff) = @_;
    my $a = $diff->{attribute};
    my $t = $diff->{table_value} // '';
    my $r = $diff->{result_value} // '';
    $t = '(empty)' if $t eq '';
    $r = '(empty)' if $r eq '';
    return "Column $a differs: live=$t, Result=$r";
}

sub _issue {
    my ($table, $column, $kind, $tv, $rv, $msg) = @_;
    return {
        table         => $table,
        column        => $column,
        kind          => $kind,
        attribute     => $kind,
        table_value   => defined $tv ? $tv : '',
        result_value  => defined $rv ? $rv : '',
        message       => $msg,
        # Result file is the source of truth; the Result side is the intended shape.
        authority     => 'Result',
    };
}

sub _pack {
    my ($issues) = @_;
    return {
        has_problem  => @$issues ? 1 : 0,
        issue_count  => scalar(@$issues),
        issues       => $issues,
    };
}

1;
