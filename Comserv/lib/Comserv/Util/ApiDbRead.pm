package Comserv::Util::ApiDbRead;

use strict;
use warnings;

=head1 NAME

Comserv::Util::ApiDbRead - read-only, allow-listed table reads for GET /api/db/read

=head1 DESCRIPTION

Pure logic (no Catalyst) behind C<GET /api/db/read>. Everything a caller sends is
validated against the live DBIx::Class schema: table names must be real source
table names, column names must be real columns of that table, and values only ever
travel as bind parameters through DBIC C<search>. No raw SQL and no user text is
ever interpolated into SQL.

Secrets protection (review this block first):

=over 4

=item * C<%BLOCKED_TABLE> / C<@BLOCKED_TABLE_RE> - tables that can never be read.

=item * C<@MASK_COLUMN_RE> / C<@MASK_COLUMN_SUFFIX_RE> - columns whose value is never read
from the database; the response shows the literal C<***masked***> instead. Masked columns
also cannot be used in C<filter>, C<order> (that would leak values by probing).

=item * C<%FORCE_MASK_COLUMN> - explicit per-table column masks that the patterns miss.

=item * C<%ALLOW_COLUMN>, C<%ALLOW_TABLE> - explicit exceptions to the patterns (harmless false positives).

=item * C<%KEY_VALUE_TABLE> - key/value tables where the value is masked only on rows whose
key looks secret (the value column cannot be filtered or ordered on).

=back

=cut

our $MASK = '***masked***';

our $DEFAULT_LIMIT = 100;
our $MAX_LIMIT     = 500;
our $MAX_OFFSET    = 10_000_000;
our $MAX_FILTERS   = 10;
our $MAX_IN_VALUES = 50;
our $MAX_VALUE_LEN = 500;
our $MAX_CELL_LEN  = 5000;

# ---- allow / deny lists (edit here, keep short and reviewable) --------------

# Tables that are never readable through this endpoint.
our %BLOCKED_TABLE = map { $_ => 1 } qw(
    app_secrets
    api_tokens
    session
    sessions
    ai_support_sessions
    user_api_keys
    env_variables
    env_variable_audit_logs
    password_reset_tokens
    email_verification_codes
);

# Tables the name patterns below would block by mistake (harmless: not credentials).
our %ALLOW_TABLE = map { $_ => 1 } qw(
    inventory_count_sessions
);

# Pattern-based table blocks (secret/credential/vault/session/token-like names).
our @BLOCKED_TABLE_RE = (
    qr/(^|_)(secrets?|credentials?|vault|sessions?|tokens?|passwords?)(_|$)/i,
);

# Column names (whole-word style, split on _) that are masked in every table.
our @MASK_COLUMN_RE = (
    qr/(^|_)(password|passwd|pass|hash|secret|token|api_?key|private_?key|cookie|session)(_|$)/i,
);
# Column-name suffixes that are masked in every table.
our @MASK_COLUMN_SUFFIX_RE = (
    qr/(_enc|_encrypted|_salt)$/i,
);

# Extra per-table column masks the patterns above miss (table => [columns]).
our %FORCE_MASK_COLUMN = (
    membership_promo_codes => [qw(code)],
    mailing_lists          => [qw(backend_config)],
);

# Explicit per-table exceptions: a column listed here is NOT masked by the patterns.
our %ALLOW_COLUMN = (
    weather_providers => [qw(requires_api_key)],   # boolean flag, not a key
);

# Key/value tables: table => [key_column, value_column]. Value is masked on rows whose
# key matches the secret pattern below; value column cannot be filtered/ordered on.
our %KEY_VALUE_TABLE = (
    site_config      => [qw(config_key config_value)],
    user_preferences => [qw(pref_key pref_value)],
);
our $SECRET_KEY_RE = qr/(password|passwd|passphrase|secret|token|api_?key|private_?key|credential|cookie|_enc$|_pass$|auth)/i;

# Allowed filter operators: name => DBIC operator
our %OPERATOR = (
    eq   => '=',
    ne   => '!=',
    like => 'like',
    gt   => '>',
    lt   => '<',
    ge   => '>=',
    le   => '<=',
    in   => 'in',
);

# ---- helpers ----------------------------------------------------------------

sub _fail {
    my ($status, $code, $msg) = @_;
    die { status => $status, code => $code, error => $msg };
}

sub is_blocked_table {
    my ($class, $table) = @_;
    return 1 if $BLOCKED_TABLE{ lc $table };
    return 0 if $ALLOW_TABLE{ lc $table };
    return 1 if grep { $table =~ $_ } @BLOCKED_TABLE_RE;
    return 0;
}

sub is_masked_column {
    my ($class, $table, $col) = @_;
    return 0 if grep { lc($_) eq lc($col) } @{ $ALLOW_COLUMN{$table} || [] };
    return 1 if grep { lc($_) eq lc($col) } @{ $FORCE_MASK_COLUMN{$table} || [] };
    return 1 if grep { $col =~ $_ } @MASK_COLUMN_RE, @MASK_COLUMN_SUFFIX_RE;
    return 0;
}

# Table name => source name, built from the schema itself (never from user text).
sub table_map {
    my ($class, $schema) = @_;
    my %map;
    for my $sn ($schema->sources) {
        my $name = eval { $schema->source($sn)->name };
        next unless defined $name && !ref($name) && $name =~ /^[A-Za-z_][A-Za-z0-9_]*$/;
        $map{$name} = $sn;
    }
    return \%map;
}

# Sorted list of readable table names.
sub readable_tables {
    my ($class, $schema) = @_;
    my $map = $class->table_map($schema);
    return [ sort grep { !$class->is_blocked_table($_) } keys %$map ];
}

sub blocked_tables {
    my ($class, $schema) = @_;
    my $map = $class->table_map($schema);
    return [ sort grep { $class->is_blocked_table($_) } keys %$map ];
}

sub _parse_filters {
    my ($raw) = @_;
    my @parts;
    for my $r (ref($raw) eq 'ARRAY' ? @$raw : (defined $raw ? ($raw) : ())) {
        next unless defined $r && length $r;
        # split on commas that start a new "col:" / "col__op:" item; commas inside values stay
        push @parts, split /,(?=[A-Za-z_][A-Za-z0-9_]*(?:__[a-z]+)?:)/, $r;
    }
    _fail(400, 'too_many_filters', "At most $MAX_FILTERS filters") if @parts > $MAX_FILTERS;
    my @out;
    for my $p (@parts) {
        $p =~ /^([A-Za-z_][A-Za-z0-9_]*?)(?:__([a-z]+))?:(.*)\z/s
            or _fail(400, 'bad_filter', 'Filter must look like column:value or column__op:value');
        my ($col, $op, $val) = ($1, $2, $3);
        if (defined $op && !exists $OPERATOR{$op}) {
            # not an operator: it is part of a column name containing "__" (checked against the schema later)
            $col = "${col}__$op"; $op = undef;
        }
        $op //= 'eq';
        _fail(400, 'value_too_long', "Filter value too long (max $MAX_VALUE_LEN)")
            if length($val) > $MAX_VALUE_LEN;
        push @out, { col => $col, op => $op, val => $val };
    }
    return \@out;
}

sub _int_param {
    my ($v, $name, $default, $min, $max, $clamp) = @_;
    return $default unless defined $v && length $v;
    _fail(400, "bad_$name", "$name must be a non-negative integer") unless !ref($v) && $v =~ /^\d{1,12}\z/;
    $v += 0;
    _fail(400, "bad_$name", "$name must be >= $min") if $v < $min;
    if ($v > $max) {
        _fail(400, "bad_$name", "$name must be <= $max") unless $clamp;
        $v = $max;
    }
    return $v;
}

=head1 METHODS

=head2 query($schema, \%params)

C<%params>: C<table>, C<filter>, C<columns>, C<limit>, C<offset>, C<order>, C<total>.
Returns a hashref (see below) or dies with C<{status, code, error}>.

When C<table> is missing returns C<< { tables => [...] } >> (readable table names).

Result keys: table, columns, masked_columns, limit, offset, count, has_more,
filter_columns (names only), rows, and total_count when C<total=1> was given.

=cut

sub query {
    my ($class, $schema, $p) = @_;
    $p ||= {};

    for my $k (qw(table columns order limit offset total)) {
        _fail(400, 'bad_param', "$k must be given once") if ref $p->{$k};
    }

    my $table = $p->{table};
    unless (defined $table && length $table) {
        return { tables => $class->readable_tables($schema) };
    }
    _fail(400, 'bad_table', 'table must be a single table name')
        if ref($table) || $table !~ /^[A-Za-z_][A-Za-z0-9_]{0,63}\z/;

    my $map = $class->table_map($schema);
    _fail(404, 'unknown_table', 'Unknown table') unless exists $map->{$table};
    _fail(403, 'table_blocked', 'This table cannot be read through the API')
        if $class->is_blocked_table($table);

    my $source = $schema->source($map->{$table});
    my @all_cols = $source->columns;
    my %is_col   = map { $_ => 1 } @all_cols;
    my %masked   = map { $_ => 1 } grep { $class->is_masked_column($table, $_) } @all_cols;
    my @plain    = grep { !$masked{$_} } @all_cols;
    _fail(403, 'table_blocked', 'This table has no readable columns') unless @plain;

    my ($kv_key, $kv_val);
    if (my $kv = $KEY_VALUE_TABLE{$table}) {
        ($kv_key, $kv_val) = @$kv if $is_col{ $kv->[0] } && $is_col{ $kv->[1] };
    }
    my %nofilter = (%masked, ($kv_val ? ($kv_val => 1) : ()));

    # requested columns
    my @want;
    if (defined $p->{columns} && length($p->{columns})) {
        for my $c (split /,/, $p->{columns}) {
            $c =~ s/^\s+|\s+$//g;
            next unless length $c;
            _fail(400, 'bad_column', "Unknown column '" . _safe($c) . "'")
                unless $c =~ /^[A-Za-z_][A-Za-z0-9_]*\z/ && $is_col{$c};
            push @want, $c unless grep { $_ eq $c } @want;
        }
        _fail(400, 'bad_column', 'columns is empty') unless @want;
    } else {
        @want = @all_cols;
    }
    my $columns_requested = @want;

    # filters
    my $filters = _parse_filters($p->{filter});
    my @conds;
    my @filter_cols;
    for my $f (@$filters) {
        _fail(400, 'bad_filter_column', "Unknown filter column '" . _safe($f->{col}) . "'")
            unless $is_col{ $f->{col} };
        _fail(403, 'masked_column', "Column '$f->{col}' is masked and cannot be filtered on")
            if $nofilter{ $f->{col} };
        my $op = $f->{op};
        my $cond;
        if ($op eq 'in') {
            my @vals = split /\|/, $f->{val}, -1;
            _fail(400, 'bad_filter', 'in needs 1..' . $MAX_IN_VALUES . ' values separated by |')
                if !@vals || @vals > $MAX_IN_VALUES;
            $cond = { $f->{col} => { -in => \@vals } };
        } else {
            $cond = { $f->{col} => { $OPERATOR{$op} => $f->{val} } };
        }
        push @conds, $cond;
        push @filter_cols, $f->{col} unless grep { $_ eq $f->{col} } @filter_cols;
    }

    # order
    my @order;
    if (defined $p->{order} && length($p->{order})) {
        my @items = split /,/, $p->{order};
        _fail(400, 'bad_order', 'At most 3 order columns') if @items > 3;
        for my $it (@items) {
            $it =~ s/^\s+|\s+$//g;
            $it =~ /^([A-Za-z_][A-Za-z0-9_]*)(?::(asc|desc))?\z/i
                or _fail(400, 'bad_order', 'order must look like column or column:desc');
            my ($oc, $dir) = ($1, lc($2 // 'asc'));
            _fail(400, 'bad_order', "Unknown order column '" . _safe($oc) . "'") unless $is_col{$oc};
            _fail(403, 'masked_column', "Column '$oc' is masked and cannot be ordered on") if $nofilter{$oc};
            push @order, { "-$dir" => $oc };
        }
    }

    my $limit  = _int_param($p->{limit},  'limit',  $DEFAULT_LIMIT, 1, $MAX_LIMIT, 1);
    my $offset = _int_param($p->{offset}, 'offset', 0, 0, $MAX_OFFSET, 0);

    # columns actually fetched from the DB: never the masked ones
    my @fetch = grep { !$masked{$_} } @want;
    my %fetch_set = map { $_ => 1 } @fetch;
    my $added_key = 0;
    if ($kv_val && $fetch_set{$kv_val} && !$fetch_set{$kv_key}) {
        push @fetch, $kv_key; $added_key = 1;
    }
    push @fetch, $plain[0] unless @fetch;   # only masked columns requested: still need a row source

    my $rs = $schema->resultset($map->{$table});
    my %attr = (
        columns      => \@fetch,
        rows         => $limit + 1,
        result_class => 'DBIx::Class::ResultClass::HashRefInflator',
    );
    $attr{offset}   = $offset if $offset;
    $attr{order_by} = \@order if @order;
    unless (@order) {
        # stable paging: default to the first primary key column (when readable)
        my ($pk) = grep { !$masked{$_} } $source->primary_columns;
        $attr{order_by} = [ { -asc => $pk } ] if defined $pk;
    }

    my $where = @conds ? { -and => \@conds } : {};
    my @rows = $rs->search($where, \%attr)->all;

    my $has_more = @rows > $limit ? 1 : 0;
    splice(@rows, $limit) if $has_more;

    my @out;
    for my $r (@rows) {
        my %o;
        for my $c (@want) {
            if ($masked{$c}) { $o{$c} = $MASK; next }
            my $v = $r->{$c};
            if ($kv_val && $c eq $kv_val && defined $v && length $v
                && defined $r->{$kv_key} && $r->{$kv_key} =~ $SECRET_KEY_RE) {
                $v = $MASK;
            }
            if (defined $v && !ref($v) && length($v) > $MAX_CELL_LEN) {
                $v = substr($v, 0, $MAX_CELL_LEN) . '...[truncated]';
            }
            $o{$c} = $v;
        }
        push @out, \%o;
    }

    my %res = (
        table          => $table,
        columns        => \@want,
        masked_columns => [ grep { $masked{$_} } @want ],
        limit          => $limit,
        offset         => $offset,
        count          => scalar(@out),
        has_more       => $has_more ? \1 : \0,
        filter_columns => \@filter_cols,
        columns_requested => $columns_requested,
        rows           => \@out,
    );
    if ($p->{total} && !ref($p->{total}) && $p->{total} =~ /^(?:1|true|yes)\z/i) {
        $res{total_count} = $rs->search($where)->count;
    }
    return \%res;
}

sub _safe {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/[^A-Za-z0-9_]/?/g;
    return substr($s, 0, 64);
}

1;
