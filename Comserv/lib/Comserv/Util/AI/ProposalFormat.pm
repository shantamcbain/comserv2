package Comserv::Util::AI::ProposalFormat;

# Eval proposal format (Oct 10 2026): every proposal renders
#   Problem  - what happened, when, evidence (session / log / rows)
#   Impact   - $, quota, failures
#   Solution - the concrete change in plain words
#   Risk     - risk and how to undo
# Reporters send them as top-level proposal fields (problem/impact/solution/risk)
# or inside payload.format. Missing ones are DERIVED from title/rationale/
# target/payload and listed in {derived} so the page can say so.

use strict;
use warnings;

our @FIELDS = qw(problem impact solution risk);
our %LABEL = (problem => 'Problem', impact => 'Impact', solution => 'Solution', risk => 'Risk / undo');

sub _s { my ($v) = @_; return undef unless defined $v && !ref $v; $v =~ s/^\s+|\s+$//g; return length $v ? $v : undef }

sub _sentences { my ($t) = @_; return () unless defined $t; return grep { /\S/ } split /(?<=[.!?])\s+|\n+/, $t }

# normalize($proposal_hash, $payload) -> { problem, impact, solution, risk, derived => [...] }
sub normalize {
    my ($p, $payload) = @_;
    $p ||= {};
    my $fmt = ref $payload eq 'HASH' && ref $payload->{format} eq 'HASH' ? $payload->{format} : {};
    my (%o, @derived);
    for my $f (@FIELDS) {
        $o{$f} = _s($p->{$f}) // _s($fmt->{$f}) // (ref $payload eq 'HASH' ? _s($payload->{$f}) : undef);
    }
    my $rat = _s($p->{rationale}) // '';
    my @sent = _sentences($rat);
    unless (defined $o{problem}) {
        $o{problem} = length $rat ? (length $rat > 700 ? substr($rat, 0, 700) . '...' : $rat) : _s($p->{title}) // '(not stated)';
        push @derived, 'problem';
    }
    unless (defined $o{impact}) {
        my @hit = grep { /\$\s?\d|\d\s?%|quota|fail|error|cost|tokens|calls|down|broke|lost|slow|wasted|429/i } @sent;
        $o{impact} = @hit ? join(' ', @hit[0 .. ($#hit < 1 ? $#hit : 1)]) : 'Not stated by the reporter.';
        push @derived, 'impact';
    }
    unless (defined $o{solution}) {
        my $t = _s($p->{title}) // '';
        my $tg = _s($p->{target});
        my $v = ref $payload eq 'HASH' && exists $payload->{value} ? $payload->{value} : undef;
        my $vs = defined $v ? (ref $v ? JSON::PP->new->canonical->encode($v) : $v) : undef;
        $o{solution} = $t . (defined $tg ? " (change: $tg" . (defined $vs ? " -> $vs" : '') . ')' : '');
        push @derived, 'solution';
    }
    unless (defined $o{risk}) {
        my $u = ref $payload eq 'HASH' ? (_s($payload->{undo}) // _s($payload->{revert}) // _s($payload->{rollback})) : undef;
        ($u) = grep { /\b(?:undo|revert|roll ?back|restore)\b/i } @sent unless defined $u;
        $o{risk} = $u // (($p->{change_type} // '') eq 'config'
            ? 'Low: config change on an allow-listed key; the Revert button on /ai/eval restores the previous value.'
            : 'Not stated - check with Shanta before applying; undo = revert the change by hand.');
        push @derived, 'risk';
    }
    $o{derived} = \@derived;
    return \%o;
}

# For ingest: fold the four fields into the payload hash (payload.format).
# Returns (new_payload, \@derived). Non-hash payloads are left alone (derived at render).
sub fold_into_payload {
    my ($p, $payload) = @_;
    my $n = normalize($p, $payload);
    return ($payload, $n->{derived}) if defined $payload && ref $payload ne 'HASH';
    my %pl = %{ $payload || {} };
    $pl{format} = { map { ($_ => $n->{$_}) } @FIELDS };
    $pl{format}{derived} = $n->{derived} if @{ $n->{derived} };
    return (\%pl, $n->{derived});
}

require JSON::PP;
1;
