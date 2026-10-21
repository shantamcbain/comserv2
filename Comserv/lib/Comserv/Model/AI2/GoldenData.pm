package Comserv::Model::AI2::GoldenData;

use Moose;
use namespace::autoclean -except => [qw(try catch finally)];
use Try::Tiny;
use Digest::SHA qw(sha256_hex);

extends 'Catalyst::Model';

has 'logger' => (
    is      => 'rw',
    lazy    => 1,
    default => sub { require Comserv::Util::Logging; Comserv::Util::Logging->instance },
);

# Tests / scripts may inject a DBIx::Class schema instead of $c->model('DBEncy').
has 'schema_override' => ( is => 'rw', default => undef );

use constant DEFAULT_LIMIT => 6;
use constant MAX_LIMIT     => 50;
use constant STATUSES      => qw(candidate in_review golden rejected stale);
# Candidate Data = everything that has NOT passed review.
use constant CANDIDATE_STATUSES => qw(candidate in_review);

# ===================================================================
# AI2::GoldenData — read/ingest service for the Golden Data store
# (ai_golden_data, Result::AiGoldenData). See Comserv::Util::AI::Glossary.
#
# Hard rules:
#  - ingest_candidate() ALWAYS writes status=candidate. There is no code path
#    that promotes a row to golden; only a human review does that.
#  - Degrades gracefully while the table has not been created yet
#    (schema-compare pending): every read returns empty + table_missing=1.
# ===================================================================

sub _schema {
    my ($self, $c) = @_;
    return $self->schema_override if $self->schema_override;
    return $c->model('DBEncy')->schema;
}

sub _log {
    my ($self, $c, $level, $sub, $msg) = @_;
    eval { $self->logger->log_with_details($c, $level, __FILE__, __LINE__, $sub, $msg) };
}

# True when an exception means "table / source not there yet".
sub _is_missing_error {
    my ($self, $err) = @_;
    $err = "$err";
    return ($err =~ /doesn't exist|does not exist|no such table|Unknown table|Can't find source|No such source/i) ? 1 : 0;
}

sub _keywords {
    my ($self, $q) = @_;
    return () unless defined $q && length $q;
    my %stop = map { $_ => 1 } qw(what when where which about tell with from that this have does used
        they them there their into your ours info information please could would should);
    my (@kw, %seen);
    for my $w (split /\W+/, lc $q) {
        next if length($w) < 4 || $stop{$w} || $seen{$w}++;
        push @kw, $w;
        last if @kw >= 5;
    }
    return @kw;
}

sub _row_to_hash {
    my ($self, $r) = @_;
    my $upd = $r->get_column('updated_at');
    return {
        id             => $r->id,
        domain         => $r->domain,
        title          => $r->title,
        canonical_text => $r->canonical_text,
        source_ref     => $r->source_ref,
        status         => $r->status,
        version        => $r->version,
        updated_at     => (defined $upd ? "$upd" : undef),
    };
}

sub _list {
    my ($self, $c, $sub, $status_cond, %a) = @_;
    my $limit = $a{limit} && $a{limit} =~ /^\d+$/ ? $a{limit} : DEFAULT_LIMIT;
    $limit = MAX_LIMIT if $limit > MAX_LIMIT;
    my %cond = ( status => $status_cond );
    $cond{domain} = lc $a{domain} if defined $a{domain} && length $a{domain};
    my @kw = $self->_keywords($a{query});
    if (@kw) {
        $cond{-or} = [ map { ( { title => { -like => "%$_%" } },
                               { canonical_text => { -like => "%$_%" } } ) } @kw ];
    }
    my $out = { rows => [], table_missing => 0 };
    try {
        my @rows = $self->_schema($c)->resultset('AiGoldenData')->search(\%cond, {
            order_by => [ { -desc => 'updated_at' }, { -desc => 'id' } ],
            rows     => $limit,
        })->all;
        $out->{rows} = [ map { $self->_row_to_hash($_) } @rows ];
    } catch {
        my $e = $_;
        if ($self->_is_missing_error($e)) {
            $out->{table_missing} = 1;
            $self->_log($c, 'info', $sub,
                "Golden Data store not available yet (ai_golden_data table pending schema-compare): $e");
        } else {
            $out->{error} = "$e";
            $self->_log($c, 'warn', $sub, "Golden Data store read failed: $e");
        }
    };
    return $out;
}

=head2 list_golden($c, domain => $d, limit => $n, query => $q)

Rows with status=golden only (Golden Data). Returns
C<< { rows => [...], table_missing => 0|1 } >>.

=cut

sub list_golden {
    my ($self, $c, %a) = @_;
    return $self->_list($c, 'list_golden', 'golden', %a);
}

=head2 list_candidates($c, domain => $d, limit => $n, query => $q)

Rows with status candidate or in_review (Candidate Data — unverified).

=cut

sub list_candidates {
    my ($self, $c, %a) = @_;
    return $self->_list($c, 'list_candidates', { -in => [ CANDIDATE_STATUSES ] }, %a);
}

=head2 counts_by_status($c)

C<< { counts => { candidate => n, in_review => n, golden => n, rejected => n, stale => n },
total => n, table_missing => 0|1 } >> via a DBIx::Class group_by.

=cut

sub counts_by_status {
    my ($self, $c) = @_;
    my %counts = map { $_ => 0 } STATUSES;
    my $out = { counts => \%counts, total => 0, table_missing => 0 };
    try {
        my $rs = $self->_schema($c)->resultset('AiGoldenData')->search({}, {
            select   => [ 'status', { count => 'id', -as => 'n' } ],
            as       => [ 'status', 'n' ],
            group_by => [ 'status' ],
        });
        while (my $r = $rs->next) {
            my $s = $r->get_column('status') // 'unknown';
            my $n = $r->get_column('n') || 0;
            $counts{$s} = ($counts{$s} || 0) + $n;
            $out->{total} += $n;
        }
    } catch {
        my $e = $_;
        if ($self->_is_missing_error($e)) {
            $out->{table_missing} = 1;
        } else {
            $out->{error} = "$e";
            $self->_log($c, 'warn', 'counts_by_status', "Golden Data counts failed: $e");
        }
    };
    return $out;
}

=head2 ingest_candidate($c, domain =>, title =>, canonical_text =>, source_ref =>)

Adds Candidate Data. B<Always> status=candidate regardless of arguments (no
auto-promotion). Dedups on content_hash (sha256 of canonical_text). Returns
C<< { ok => 1, id => n, duplicate => 0|1 } >> or C<< { ok => 0, error => ..., table_missing => 0|1 } >>.

=cut

sub ingest_candidate {
    my ($self, $c, %a) = @_;
    my $title = defined $a{title} ? substr($a{title}, 0, 255) : '';
    my $text  = $a{canonical_text} // '';
    return { ok => 0, error => 'title and canonical_text are required' }
        unless length $title && length $text;

    if (defined $a{status} && $a{status} ne 'candidate') {
        $self->_log($c, 'warn', 'ingest_candidate',
            "Ignored requested status '$a{status}' — ingest only ever writes Candidate Data (status=candidate)");
    }
    my $domain = lc($a{domain} // 'app_docs');
    $domain = substr($domain, 0, 50);
    my $hash = sha256_hex(do { my $t = $text; utf8::encode($t) if utf8::is_utf8($t); $t });

    my $out;
    try {
        my $rs = $self->_schema($c)->resultset('AiGoldenData');
        my $dup = $rs->search({ content_hash => $hash }, { rows => 1 })->single;
        if ($dup) {
            $out = { ok => 1, id => $dup->id, duplicate => 1 };
            return;
        }
        my $row = $rs->create({
            domain         => $domain,
            title          => $title,
            canonical_text => $text,
            source_ref     => (defined $a{source_ref} ? substr($a{source_ref}, 0, 2000) : undef),
            status         => 'candidate',   # never anything else from code
            version        => 1,
            content_hash   => $hash,
        });
        $out = { ok => 1, id => $row->id, duplicate => 0 };
        $self->_log($c, 'info', 'ingest_candidate',
            "Candidate Data ingested id=" . $row->id . " domain=$domain source_ref=" . ($a{source_ref} // '-'));
    } catch {
        my $e = $_;
        $out = { ok => 0, error => "$e", table_missing => $self->_is_missing_error($e) };
        $self->_log($c, 'warn', 'ingest_candidate', "Candidate ingest failed: $e");
    };
    return $out;
}

__PACKAGE__->meta->make_immutable;

1;

__END__

=head1 NAME

Comserv::Model::AI2::GoldenData - Golden Data store service (ai_golden_data)

=head1 DESCRIPTION

Reads Golden Data (status=golden, human-agreed truth) and Candidate Data
(candidate / in_review) for Grounding (L<Comserv::Model::AI2::Grounding>), counts
rows by status for the AI Usage monitor, and ingests new Candidate Data.

Golden Data status today: B<EMPTY / NOT YET QUALIFIED>. The table itself is
created by an admin through in-app schema-compare; until then every method
returns empty results with C<table_missing =E<gt> 1>.

=head2 Domains

Known values (varchar, other values accepted): C<policy> (corporate policy),
C<research> (verified research, e.g. herbal), C<app_docs> (how the app runs),
C<todo>, C<customer>.

=head2 source_ref convention

C<< <type>:<locator> >> — C<policy:...>, C<research:ency_herb_tb:4>,
C<app_docs:Documentation/X>, C<web:searxng:<url>>.

=head2 Review-first queue

Corporate policy docs, research tables (e.g. C<ency.ency_herb_tb>) and app
documentation are the best Candidate Data to review first. Nothing is
bulk-imported and nothing is promoted automatically.

=cut
