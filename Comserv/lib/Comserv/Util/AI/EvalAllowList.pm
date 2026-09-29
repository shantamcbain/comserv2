package Comserv::Util::AI::EvalAllowList;

# ===================================================================
# The ONE allow-list of config changes a Daily AI Eval Report proposal may
# apply from /ai/eval (AISYSTEM plan §5d). Anything not listed here is
# rejected. Each entry: file (under root/config), key (top-level JSON key),
# and a validator (enum | int range | number range | bool | slug_list).
#
# Router: model/provider routing preferences are NOT in any config file today
# (FREE_PREFERENCE in Util/ModelCatalog.pm and _default_free_catalog in
# Model/AI2/Router.pm are Perl code), so no routing key is allow-listed —
# routing proposals are change_type=code and become todos.
# Token/spend caps: only root/config/ai_usage.json has caps (SuperGrok
# monthly USD / request limits + alert %). OpenRouter soft caps
# ($1.65/day, $11.50/week, $50/month) are not stored in any app config.
#
# Writes are atomic (temp file in the same dir + rename) and keep the file's
# top-level key order and 2-space pretty formatting.
# ===================================================================

use strict;
use warnings;
use JSON ();
use File::Temp ();
use File::Basename qw(dirname);
use Scalar::Util qw(looks_like_number);

our %ALLOW = (
    'ai_grounding.json:mode' => {
        type => 'enum', values => [qw(off shadow enforce)],
        help => 'Grounding mode (Model::AI2::Grounding): off | shadow | enforce',
    },
    'ai_grounding.json:max_snippets' => {
        type => 'int', min => 1, max => 20,
        help => 'Max Grounding Context snippets per factual turn',
    },
    'ai_grounding.json:max_total_chars' => {
        type => 'int', min => 500, max => 20000,
        help => 'Max total Grounding Context characters',
    },
    'ai_grounding.json:postcheck_action' => {
        type => 'enum', values => [qw(strip flag)],
        help => 'Uncited factual sentences: strip or flag',
    },
    'ai_grounding.json:web_search' => {
        type => 'bool',
        help => 'Live SearXNG retrieval in enforce mode (0/1)',
    },
    'ai_usage.json:alert_percent' => {
        type => 'int', min => 1, max => 100,
        help => 'SuperGrok monthly allowance alert threshold (%)',
    },
    'ai_usage.json:supergrok_monthly_limit_usd' => {
        type => 'number', min => 0, max => 500,
        help => 'SuperGrok monthly spend cap used by the usage monitor (USD)',
    },
    'ai_usage.json:supergrok_monthly_request_limit' => {
        type => 'int', min => 0, max => 100000,
        help => 'SuperGrok monthly request cap used by the usage monitor',
    },
);

sub new {
    my ($class, %a) = @_;
    my $self = bless {
        config_dir => $a{config_dir},            # required for apply/revert
        allow      => $a{allow} || \%ALLOW,      # tests may inject
        known_slugs => $a{known_slugs},          # arrayref for slug_list
    }, $class;
    return $self;
}

sub allow { $_[0]{allow} }

# Sorted list for display: [{ target, file, key, type, allowed }]
sub describe {
    my ($self) = @_;
    my @out;
    for my $t (sort keys %{ $self->{allow} }) {
        my $r = $self->{allow}{$t};
        my ($file, $key) = split /:/, $t, 2;
        my $allowed = $r->{type} eq 'enum'   ? join(' | ', @{ $r->{values} })
                    : $r->{type} eq 'bool'   ? '0 | 1'
                    : $r->{type} =~ /^(int|number)$/ ? "$r->{type} $r->{min}..$r->{max}"
                    : $r->{type} eq 'slug_list' ? 'list of known model slugs'
                    : $r->{type};
        push @out, { target => $t, file => $file, key => $key, type => $r->{type},
                     allowed => $allowed, help => $r->{help} // '' };
    }
    return \@out;
}

sub is_allowed { my ($self, $t) = @_; return (defined $t && exists $self->{allow}{$t}) ? 1 : 0 }

# validate($target, $value) -> ($ok, $normalized_value_or_error)
sub validate {
    my ($self, $target, $value) = @_;
    return (0, 'target is not allow-listed: ' . ($target // '(none)')) unless $self->is_allowed($target);
    my $r = $self->{allow}{$target};
    my ($file, $key) = split /:/, $target, 2;
    return (0, "bad target format: $target") unless defined $key && length $key && $file =~ /^[A-Za-z0-9_.-]+\.json$/;
    return (0, 'value is required') unless defined $value;
    return (0, 'value must be a scalar') if ref $value && !JSON::is_bool($value) && $r->{type} ne 'slug_list';
    my $t = $r->{type};
    if ($t eq 'enum') {
        my %ok = map { $_ => 1 } @{ $r->{values} };
        return $ok{$value} ? (1, "$value") : (0, "value '$value' not in: " . join('|', @{ $r->{values} }));
    }
    if ($t eq 'int') {
        return (0, "value '$value' is not an integer") unless "$value" =~ /^-?\d+$/;
        return (0, "value $value out of range $r->{min}..$r->{max}") if $value < $r->{min} || $value > $r->{max};
        return (1, 0 + $value);
    }
    if ($t eq 'number') {
        return (0, "value '$value' is not a number") unless looks_like_number("$value") && "$value" !~ /inf|nan/i;
        return (0, "value $value out of range $r->{min}..$r->{max}") if $value < $r->{min} || $value > $r->{max};
        return (1, 0 + $value);
    }
    if ($t eq 'bool') {
        my $v = JSON::is_bool($value) ? ($value ? 1 : 0) : "$value";
        return (0, "value '$v' is not 0/1") unless $v =~ /^[01]$/;
        return (1, 0 + $v);
    }
    if ($t eq 'slug_list') {
        return (0, 'value must be a list of model slugs') unless ref $value eq 'ARRAY';
        my %known = map { $_ => 1 } @{ $self->{known_slugs} || [] };
        for my $s (@$value) {
            return (0, 'slug must be a string') if ref $s || !defined $s;
            return (0, "unknown model slug: $s") unless $known{$s};
        }
        return (1, [ @$value ]);
    }
    return (0, "unsupported validator type: $t");
}

sub _path {
    my ($self, $file) = @_;
    die "config_dir not set\n" unless $self->{config_dir};
    die "bad file name\n" unless $file =~ /^[A-Za-z0-9_.-]+\.json$/ && $file !~ /\.\./;
    return "$self->{config_dir}/$file";
}

sub _read {
    my ($self, $path) = @_;
    open my $fh, '<:raw', $path or die "cannot read $path: $!\n";
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $data = JSON->new->utf8->decode($raw);
    die "$path is not a JSON object\n" unless ref $data eq 'HASH';
    return ($data, $raw);
}

# Pretty-print a flat-ish object keeping the original top-level key order
# (new keys appended sorted). Values encoded canonically.
sub _encode_ordered {
    my ($self, $data, $raw) = @_;
    my $enc = JSON->new->utf8->canonical->allow_nonref;
    my %pos;
    for my $k (keys %$data) {
        my $needle = $enc->encode("$k");
        if ($raw =~ /\Q$needle\E\s*:/g) { $pos{$k} = $-[0] }
        pos($raw) = 0;
    }
    my @keys = sort {
        (defined $pos{$a} ? 0 : 1) <=> (defined $pos{$b} ? 0 : 1)
        || ($pos{$a} // 0) <=> ($pos{$b} // 0)
        || $a cmp $b
    } keys %$data;
    my @lines = map { '  ' . $enc->encode("$_") . ': ' . $enc->encode($data->{$_}) } @keys;
    return "{\n" . join(",\n", @lines) . "\n}\n";
}

sub _write_atomic {
    my ($self, $path, $content) = @_;
    my $dir = dirname($path);
    my $mode = (stat $path)[2];
    my $tmp = File::Temp->new(DIR => $dir, TEMPLATE => '.ai_eval_XXXXXX', UNLINK => 0);
    binmode $tmp, ':raw';
    print {$tmp} $content or die "write failed: $!\n";
    close $tmp or die "close failed: $!\n";
    chmod(($mode & 07777), $tmp->filename) if defined $mode;
    unless (rename $tmp->filename, $path) {
        my $e = $!;
        unlink $tmp->filename;
        die "rename failed: $e\n";
    }
    return 1;
}

# current($target) -> { present => 0|1, value => ... }
sub current {
    my ($self, $target) = @_;
    my ($file, $key) = split /:/, $target, 2;
    my ($data) = $self->_read($self->_path($file));
    return exists $data->{$key} ? { present => 1, value => $data->{$key} } : { present => 0, value => undef };
}

# apply($target, $value) -> { ok, before => {present,value}, after, file } or { ok=>0, error }
sub apply {
    my ($self, $target, $value) = @_;
    my ($ok, $norm) = $self->validate($target, $value);
    return { ok => 0, error => $norm } unless $ok;
    my ($file, $key) = split /:/, $target, 2;
    my $out;
    eval {
        my $path = $self->_path($file);
        my ($data, $raw) = $self->_read($path);
        my $before = exists $data->{$key} ? { present => 1, value => $data->{$key} } : { present => 0, value => undef };
        $data->{$key} = $norm;
        $self->_write_atomic($path, $self->_encode_ordered($data, $raw));
        my ($check) = $self->_read($path);
        die "verify failed after write\n"
            unless JSON->new->canonical->allow_nonref->encode($check->{$key})
                eq JSON->new->canonical->allow_nonref->encode($norm);
        $out = { ok => 1, before => $before, after => $norm, file => $file, key => $key };
        1;
    } or do {
        my $e = $@ || 'unknown error';
        chomp $e;
        $out = { ok => 0, error => $e };
    };
    return $out;
}

# restore($target, {present, value}) -> { ok, replaced => {present,value} } — used by revert.
# The target must still be allow-listed; the stored value is written as-is
# (it was the file's own value before apply) or the key is removed if absent.
sub restore {
    my ($self, $target, $before) = @_;
    return { ok => 0, error => 'target is not allow-listed: ' . ($target // '(none)') } unless $self->is_allowed($target);
    return { ok => 0, error => 'before_value missing or malformed' } unless ref $before eq 'HASH' && exists $before->{present};
    my ($file, $key) = split /:/, $target, 2;
    my $out;
    eval {
        my $path = $self->_path($file);
        my ($data, $raw) = $self->_read($path);
        my $replaced = exists $data->{$key} ? { present => 1, value => $data->{$key} } : { present => 0, value => undef };
        if ($before->{present}) { $data->{$key} = $before->{value} }
        else                    { delete $data->{$key} }
        $self->_write_atomic($path, $self->_encode_ordered($data, $raw));
        $out = { ok => 1, replaced => $replaced, file => $file, key => $key };
        1;
    } or do {
        my $e = $@ || 'unknown error';
        chomp $e;
        $out = { ok => 0, error => $e };
    };
    return $out;
}

1;

__END__

=head1 NAME

Comserv::Util::AI::EvalAllowList - allow-listed config changes for Daily AI Eval Report proposals

=head1 SYNOPSIS

    my $al = Comserv::Util::AI::EvalAllowList->new(config_dir => $c->path_to('root','config'));
    my ($ok, $v_or_err) = $al->validate('ai_grounding.json:mode', 'enforce');
    my $r = $al->apply('ai_grounding.json:mode', 'enforce');   # { ok, before, after }
    $al->restore('ai_grounding.json:mode', $r->{before});

=head1 DESCRIPTION

Single source of truth for which config keys /ai/eval may change. Unknown
targets and out-of-range values are rejected. See C<%ALLOW>.

=cut
