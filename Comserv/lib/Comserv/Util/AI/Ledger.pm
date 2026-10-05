package Comserv::Util::AI::Ledger;

# ===================================================================
# Ledger helpers (Glossary: "Ledger = append-only usage log (who, feature,
# model, tokens, cost, grounded?)"). The Ledger IS ai_usage_logs; this module
# only adds the Golden Data / grounding fields to the existing writer
# (Comserv::Model::AI::Usage::log) — it is not a second log.
#
# The new columns are declared on Result::AiUsageLog but may not exist in the
# DB until an admin syncs them via schema-compare. Until then:
#   - the fields are always stored in metadata JSON (metadata.grounding), and
#   - columns are only written when a DBIx::Class probe proves they exist.
# ===================================================================

use strict;
use warnings;

use constant LEDGER_COLUMNS => qw(grounded golden_hit_count candidate_hit_count snippet_ids flagged_count feature);
use constant PROBE_TTL_SECONDS => 300;

my %PROBE;   # schema-class => { present => 0|1, at => epoch }

# DBIx::Class probe (no raw SQL): selecting the columns fails when the DB
# table does not have them yet. Cached per process for PROBE_TTL_SECONDS.
sub columns_present {
    my ($class, $schema) = @_;
    return 0 unless $schema;
    my $key = ref($schema) || "$schema";
    my $p = $PROBE{$key};
    return $p->{present} if $p && (time - $p->{at}) < PROBE_TTL_SECONDS;
    my $ok = eval {
        $schema->resultset('AiUsageLog')->search({}, {
            columns => [ LEDGER_COLUMNS ],
            rows    => 1,
        })->first;
        1;
    } ? 1 : 0;
    $PROBE{$key} = { present => $ok, at => time };
    return $ok;
}

sub reset_probe_cache { %PROBE = () }

# Normalise the grounding hash from Grounding::ledger_fields.
sub normalise {
    my ($class, $g) = @_;
    return undef unless ref $g eq 'HASH';
    my $ids = $g->{snippet_ids};
    $ids = join(',', @$ids) if ref $ids eq 'ARRAY';
    $ids = substr($ids // '', 0, 1000);
    return {
        grounded            => ($g->{grounded} ? 1 : 0),
        golden_hit_count    => int($g->{golden_hit_count}    || 0),
        candidate_hit_count => int($g->{candidate_hit_count} || 0),
        snippet_ids         => $ids,
        flagged_count       => int($g->{flagged_count} || 0),
        feature             => substr($g->{feature} // 'ai2_chat', 0, 50),
        (defined $g->{grounding_mode} ? (grounding_mode => $g->{grounding_mode}) : ()),
        (defined $g->{factual_intent} ? (factual_intent => $g->{factual_intent}) : ()),
        (defined $g->{reason}         ? (reason         => $g->{reason})         : ()),
    };
}

# Called from Usage::log. Copies the fields into $meta->{grounding} (always)
# and returns a hashref of column values to add to the create() call (empty
# unless the DB columns exist).
sub prepare {
    my ($class, $schema, $grounding, $meta) = @_;
    my $n = $class->normalise($grounding) or return {};
    $meta->{grounding} = $n if ref $meta eq 'HASH';
    return {} unless $class->columns_present($schema);
    return { map { $_ => $n->{$_} } LEDGER_COLUMNS };
}

# Text appended to the existing "Logged AI usage" line.
sub log_suffix {
    my ($class, $grounding) = @_;
    my $n = $class->normalise($grounding) or return '';
    return sprintf(' grounded=%d golden_hit_count=%d candidate_hit_count=%d flagged_count=%d feature=%s snippet_ids=%s',
        $n->{grounded}, $n->{golden_hit_count}, $n->{candidate_hit_count},
        $n->{flagged_count}, $n->{feature}, ($n->{snippet_ids} eq '' ? '-' : $n->{snippet_ids}));
}

1;

__END__

=head1 NAME

Comserv::Util::AI::Ledger - grounding fields for the existing ai_usage_logs Ledger

=head1 DESCRIPTION

Adds C<grounded>, C<golden_hit_count>, C<candidate_hit_count>, C<snippet_ids>,
C<flagged_count> and C<feature> to every Ledger row written by
L<Comserv::Model::AI::Usage/log>. Always mirrored into C<metadata.grounding>;
written to real columns only once schema-compare has added them.

=cut
