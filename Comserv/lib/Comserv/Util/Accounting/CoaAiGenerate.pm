package Comserv::Util::Accounting::CoaAiGenerate;

use strict;
use warnings;
use Moose;
use namespace::autoclean;
use JSON;
use Comserv::Util::Logging;
use Comserv::Model::CoaTemplate;
use Comserv::Model::AccountingDB;

=head1 NAME

Comserv::Util::Accounting::CoaAiGenerate — ACCON Ph.2 AI chart draft (review before seed)

=head1 DESCRIPTION

SiteName-scoped. Starts from that site's Maria C<coa_accounts> (plus the shared
generic rows with sitename NULL). Accounts with GL / inventory / invoice activity
for THIS SiteName are locked keep. Unused generic accounts may be dropped for
this industry. Overlays come from enabled site_modules (teaching, ecommerce)
unless the owner changes the form. Entity type is chosen on the form, defaulted
from site_map (nonprofit_coop → nonprofit; everything else → sole_proprietor).

Seed writes PostgreSQL C<chart> only. Dropped accnos are stored on
C<site_accounting_dbs.notes> so migrate_to_pg will not reinsert them.

=cut

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance },
);

has 'coa' => (
    is      => 'ro',
    default => sub { Comserv::Model::CoaTemplate->new },
);

my $JSON = JSON->new->utf8(0)->canonical;
my %VALID_CAT = map { $_ => 1 } qw(A L Q I E);
my %VALID_ENTITY = map { $_ => 1 } qw(sole_proprietor corporation partnership nonprofit);

sub entity_types {
    return (
        { id => 'sole_proprietor', label => 'Sole proprietor (T2125)' },
        { id => 'corporation',     label => 'Corporation (T2 / GIFI)' },
        { id => 'partnership',     label => 'Partnership (T5013 / GIFI)' },
        { id => 'nonprofit',       label => 'Non-profit / co-op' },
    );
}

sub default_entity_type {
    my ($self, $base_id) = @_;
    return 'nonprofit' if ($base_id // '') eq 'nonprofit_coop';
    return 'sole_proprietor';
}

sub normalize_entity_type {
    my ($self, $v, $base_id) = @_;
    $v = lc($v // '');
    return $v if $VALID_ENTITY{$v};
    return $self->default_entity_type($base_id);
}

# Shared generic template (sitename NULL) + this SiteName's own rows. Never other sites.
sub maria_rows {
    my ($self, $c, $sitename) = @_;
    my @out;
    eval {
        my $rs = $c->model('DBEncy')->resultset('Accounting::CoaAccount')->search(
            {
                obsolete => 0,
                -or      => [
                    { sitename => $sitename },
                    { sitename => undef },
                    { sitename => '' },
                ],
            },
            { order_by => 'accno' },
        );
        while (my $r = $rs->next) {
            push @out, {
                accno       => $r->accno,
                description => $r->description,
                charttype   => 'A',
                category    => $r->category,
                link        => '',
                gifi_accno  => '',
                contra      => $r->is_contra ? 1 : 0,
                source      => 'maria',
                maria_scope => ($r->sitename && $r->sitename eq $sitename) ? 'site' : 'shared',
            };
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'maria_rows', "Maria CoA read failed for '$sitename': $@");
    }
    return \@out;
}

# Postings for THIS SiteName only.
sub usage_by_accno {
    my ($self, $c, $sitename) = @_;
    my %u;
    eval {
        my $schema = $c->model('DBEncy');
        my $gl = $schema->resultset('Accounting::GlEntryLine')->search(
            { 'gl_entry.sitename' => $sitename },
            { join => 'gl_entry', prefetch => 'account' },
        );
        while (my $l = $gl->next) {
            my $acc = eval { $l->account } or next;
            $u{ $acc->accno }{gl}++;
        }
        my $items = $schema->resultset('Accounting::InventoryItem')->search({ sitename => $sitename });
        while (my $it = $items->next) {
            for my $col (qw(inventory_accno_id income_accno_id expense_accno_id)) {
                next unless $it->can($col);
                my $id = $it->$col or next;
                my $acc = $schema->resultset('Accounting::CoaAccount')->find($id) or next;
                $u{ $acc->accno }{items}++;
            }
        }
        my @inv = (
            [ 'Accounting::InventoryCustomerInvoice', [qw(ar_account_id income_account_id tax_account_id)] ],
            [ 'Accounting::InventorySupplierInvoice', [qw(ap_account_id tax_account_id shipping_account_id discount_account_id)] ],
        );
        for my $pair (@inv) {
            my ($src, $cols) = @$pair;
            my $rs = eval { $schema->resultset($src)->search({ sitename => $sitename }) };
            next unless $rs;
            while (my $row = $rs->next) {
                for my $col (@$cols) {
                    next unless $row->can($col);
                    my $id = $row->$col or next;
                    my $acc = $schema->resultset('Accounting::CoaAccount')->find($id) or next;
                    $u{ $acc->accno }{invoices}++;
                }
            }
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'usage_by_accno', "Usage scan failed for '$sitename': $@");
    }
    for my $accno (keys %u) {
        my $n = ($u{$accno}{gl} || 0) + ($u{$accno}{items} || 0) + ($u{$accno}{invoices} || 0);
        $u{$accno}{in_use} = $n ? 1 : 0;
        $u{$accno}{hits}   = $n;
    }
    return \%u;
}

sub template_rows {
    my ($self, $c, $base_id, $overlays) = @_;
    $overlays ||= [];
    my $merged = eval { $self->coa->merged_chart($c, $base_id, $overlays) };
    if ($@ || !$merged) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'template_rows', "merged_chart failed: $@");
        return [];
    }
    my @out;
    for my $row (@{ $merged->{rows} || [] }) {
        push @out, {
            accno       => $row->{accno},
            description => $row->{description},
            charttype   => $row->{charttype} || 'A',
            category    => $row->{category},
            link        => $row->{link} // '',
            gifi_accno  => $row->{gifi_accno} // '',
            contra      => $row->{contra} ? 1 : 0,
            source      => $row->{_source} || "base:$base_id",
        };
    }
    return \@out;
}

sub starting_rows {
    my ($self, $c, %opt) = @_;
    my $sitename = $opt{sitename};
    my $usage = $opt{usage} || ($sitename ? $self->usage_by_accno($c, $sitename) : {});
    my $maria = $opt{use_maria} ? ($opt{maria} || $self->maria_rows($c, $sitename)) : [];
    my $tmpl  = $self->template_rows($c, $opt{base_id}, $opt{overlays} || []);
    my %by;
    my @order;
    my $add = sub {
        my ($row) = @_;
        my $k = $row->{accno} // return;
        if ($by{$k}) {
            if (($by{$k}{gifi_accno} // '') eq '' && ($row->{gifi_accno} // '') ne '') {
                $by{$k}{gifi_accno} = $row->{gifi_accno};
            }
            if (($by{$k}{link} // '') eq '' && ($row->{link} // '') ne '') {
                $by{$k}{link} = $row->{link};
            }
            return;
        }
        my %r = %$row;
        my $u = $usage->{$k} || {};
        $r{in_use} = $u->{in_use} ? 1 : 0;
        $r{hits}   = $u->{hits} || 0;
        $by{$k} = \%r;
        push @order, $k;
    };
    $add->($_) for @$maria;
    $add->($_) for @$tmpl;
    return [ map { $by{$_} } @order ];
}

sub parse_accounts_json {
    my ($self, $text) = @_;
    return (undef, 'empty AI response') unless defined $text && $text =~ /\S/;
    my $raw = $text;
    if ($raw =~ /```(?:json)?\s*(\{.*?\}|\[.*?\])\s*```/s) {
        $raw = $1;
    }
    elsif ($raw =~ /(\{[\s\S]*"accounts"[\s\S]*\})/) {
        $raw = $1;
    }
    my $data = eval { JSON->new->utf8(0)->decode($raw) };
    return (undef, "JSON parse failed: $@") if $@ || !defined $data;
    my $accounts = ref $data eq 'ARRAY' ? $data
                 : (ref $data eq 'HASH' && ref $data->{accounts} eq 'ARRAY') ? $data->{accounts}
                 : undef;
    return (undef, 'no accounts array in AI JSON') unless $accounts;
    my $notes = ref $data eq 'HASH' ? ($data->{notes} // '') : '';
    return ({ notes => $notes, accounts => $accounts }, undef);
}

sub validate_row {
    my ($self, $row) = @_;
    return unless ref $row eq 'HASH';
    my $accno = $row->{accno} // '';
    $accno =~ s/^\s+|\s+$//g;
    return unless $accno =~ /^[0-9A-Za-z.\-]{1,30}$/;
    my $cat = uc($row->{category} // '');
    return unless $VALID_CAT{$cat};
    my $desc = $row->{description} // '';
    $desc =~ s/^\s+|\s+$//g;
    return unless length $desc && length $desc <= 255;
    my $ct = uc($row->{charttype} // 'A');
    $ct = 'A' unless $ct eq 'A' || $ct eq 'H';
    my $gifi = $row->{gifi_accno} // '';
    $gifi = '' unless $gifi =~ /^[0-9]{3,6}$/;
    my $action = lc($row->{action} // 'add');
    $action = 'add' unless $action =~ /^(keep|add|change|drop)$/;
    my $in_use = $row->{in_use} ? 1 : 0;
    $action = 'keep' if $in_use && $action eq 'drop';
    return {
        accno       => $accno,
        description => $desc,
        charttype   => $ct,
        category    => $cat,
        link        => substr($row->{link} // '', 0, 80),
        gifi_accno  => $gifi,
        contra      => $row->{contra} ? 1 : 0,
        action      => $action,
        rationale   => substr($row->{rationale} // '', 0, 240),
        source      => $row->{source} // 'ai',
        in_use      => $in_use,
        hits        => $row->{hits} || 0,
        locked      => $in_use ? 1 : 0,
        selected    => ($action eq 'drop' && !$in_use) ? 0 : 1,
    };
}

# Unused Maria/template rows the model omitted become drop. In-use always keep.
sub reconcile_draft {
    my ($self, $starting, $ai_rows) = @_;
    $starting ||= [];
    $ai_rows  ||= [];
    my %ai = map { $_->{accno} => $_ } grep { $_ && $_->{accno} } @$ai_rows;
    my @out;
    my %seen;
    for my $s (@$starting) {
        my $acc = $s->{accno} or next;
        $seen{$acc} = 1;
        my $ai = $ai{$acc};
        if ($s->{in_use}) {
            my $merged = { %$s, %{ $ai || {} }, in_use => 1, hits => $s->{hits} || 0 };
            $merged->{action} = ($ai && ($ai->{action} || '') eq 'change') ? 'change' : 'keep';
            $merged->{rationale} = $ai->{rationale} if $ai && $ai->{rationale};
            $merged->{rationale} ||= 'in use on this SiteName — must keep for import';
            my $v = $self->validate_row($merged);
            push @out, $v if $v;
            next;
        }
        my $act = $ai ? ($ai->{action} || 'keep') : 'drop';
        $act = 'drop' unless $ai;
        my $merged = { %$s, %{ $ai || {} }, in_use => 0, action => $act };
        $merged->{rationale} ||= $act eq 'drop'
            ? 'unused on this SiteName; omitted from this industry chart'
            : ($ai && $ai->{rationale} ? $ai->{rationale} : '');
        my $v = $self->validate_row($merged);
        push @out, $v if $v;
    }
    for my $a (@$ai_rows) {
        next unless $a && $a->{accno};
        next if $seen{ $a->{accno} };
        next if ($a->{action} || '') eq 'drop';
        my $v = $self->validate_row({ %$a, action => $a->{action} || 'add' });
        push @out, $v if $v;
    }
    return \@out;
}

sub _industry_hint {
    my ($self, $base_id, $sitename) = @_;
    my $s = lc($sitename // '');
    if ($base_id eq 'maker_light_manufacturing' || $s eq '3d') {
        return 'Industry: maker / 3D print farm. Prefer inventory, filament/materials, equipment, COGS, production service revenue.';
    }
    if ($base_id eq 'agriculture_apiary' || $s eq 'bmaster') {
        return 'Industry: agriculture / apiary. CRA farming band 9370-9899; GIFI 9470 names apiary and honey.';
    }
    if ($base_id eq 'service_consulting' || $s eq 'csc') {
        return 'Industry: IT / hosting / programming / helpdesk. GST/HST payable is a liability, not revenue.';
    }
    if ($base_id eq 'nonprofit_coop') {
        return 'Industry: NPO/co-op. Grants 8242, gifts 8223, membership 8221; restricted funds 3745/9286.';
    }
    if ($base_id eq 'sole_proprietor') {
        return 'Industry: Canadian sole proprietor. Files T2125 not GIFI unless they later incorporate.';
    }
    return 'Use CRA GIFI bands when confident; leave gifi_accno empty rather than guessing.';
}

sub _entity_hint {
    my ($self, $entity) = @_;
    return 'Entity: Canadian sole proprietor — T2125; gifi_accno is optional future-proofing.'
        if $entity eq 'sole_proprietor';
    return 'Entity: Canadian corporation — T2 / GIFI (RC4088). Populate gifi_accno when sure.'
        if $entity eq 'corporation';
    return 'Entity: Canadian partnership — T5013 / GIFI. Populate gifi_accno when sure.'
        if $entity eq 'partnership';
    return 'Entity: Non-profit / co-op — NPO GIFI mapping (grants 8242, gifts 8223).'
        if $entity eq 'nonprofit';
    return '';
}

sub _prompt {
    my ($self, %opt) = @_;
    my $start_json = eval { $JSON->pretty(0)->encode($opt{starting} || []) } || '[]';
    my $hint = $self->_industry_hint($opt{base_id}, $opt{sitename});
    my $ov   = join(',', @{ $opt{overlays} || [] }) || '(none)';
    my $loc  = $opt{location} // '';
    my $jur  = $opt{jurisdiction} // '';
    my $cur  = $opt{currency} // '';
    my $notes = $opt{notes} // '';
    $opt{legal_form} ||= 'sole_owner';
    return <<"PROMPT";
You are proposing a chart of accounts for ONE Comserv SiteName only: '$opt{sitename}'.
Do not mix other sites. Jurisdiction: $jur. Location: $loc. Currency: $cur.
Business model (industry): $opt{base_id}.
Legal form (ownership, not industry): $opt{legal_form}.
Capability overlays (active for this site): $ov.
Legal form is generic (sole_owner, company, partnership, nonprofit, other). Do not assume Canadian T2125/T2 unless jurisdiction is CA.
$hint

Each starting row may include in_use=1 and hits=N for THIS SiteName (GL, inventory, or invoices).
Rules:
- in_use=1: action must be keep or change. Never drop. Import of existing books needs the same accno.
- in_use=0: you MAY drop accounts that do not belong in this industry (action=drop). Prefer drop over keep for unused generic accounts (e.g. filament on a consulting site, honey on a print farm).
- New industry accounts: action=add. Leave gifi_accno empty if unsure.

$start_json

Owner notes: $notes

Reply with JSON only, no markdown:
{"notes":"short human summary","accounts":[{"accno":"1000","description":"...","charttype":"A","category":"A","link":"","gifi_accno":"1000","contra":false,"action":"keep","rationale":"..."}]}
category must be A, L, Q, I, or E. action is keep, add, change, or drop.
PROMPT
}

sub generate {
    my ($self, $c, %opt) = @_;
    my $sitename = $opt{sitename} or return { success => 0, error => 'sitename required' };
    $opt{overlays} ||= [];
    my $starting = $self->starting_rows($c, %opt);
    my $prompt   = $self->_prompt(%opt, starting => $starting);

    my $resp;
    eval {
        my $router = $c->model('AI2::Router');
        $resp = $router->dispatch_chat($c, $opt{model}, [
            { role => 'system', content => 'You output valid JSON only. No prose. One SiteName only.' },
            { role => 'user',   content => $prompt },
        ]);
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'generate', "AI2 dispatch threw: $@");
        return $self->_template_fallback($c, $starting, "AI call failed: $@");
    }
    unless ($resp && $resp->{success}) {
        my $err = ($resp && $resp->{error}) || 'AI provider error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'generate', "AI failed for '$sitename': $err");
        return $self->_template_fallback($c, $starting, $err);
    }

    my $text = $resp->{response} // $resp->{content} // $resp->{text} // '';
    my ($parsed, $perr) = $self->parse_accounts_json($text);
    if ($perr) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'generate', "AI JSON unusable ($perr); using template fallback");
        return $self->_template_fallback($c, $starting, "AI returned unusable JSON ($perr)");
    }

    my @ai;
    my %seen;
    for my $raw (@{ $parsed->{accounts} }) {
        my $v = $self->validate_row($raw) or next;
        next if $seen{ $v->{accno} }++;
        push @ai, $v;
    }
    unless (@ai) {
        return $self->_template_fallback($c, $starting, 'AI returned no valid account rows');
    }

    my $rows = $self->reconcile_draft($starting, \@ai);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
        'generate', "Drafted " . scalar(@$rows) . " CoA rows for '$sitename' via "
        . ($resp->{provider} // 'ai') . ($resp->{fallback} ? ' (fallback)' : ''));

    return {
        success     => 1,
        rows        => $rows,
        notes       => $parsed->{notes} // '',
        provider    => $resp->{provider},
        model       => $resp->{model},
        fallback    => $resp->{fallback} ? 1 : 0,
        source      => 'ai',
        entity_type => $opt{entity_type},
        overlays    => $opt{overlays},
        sitename    => $sitename,
    };
}

sub _template_fallback {
    my ($self, $c, $starting, $why) = @_;
    my @ai;
    for my $s (@{ $starting || [] }) {
        my $act = $s->{in_use} ? 'keep' : (($s->{source} && $s->{source} eq 'maria') ? 'drop' : 'add');
        my $v = $self->validate_row({
            %$s,
            action    => $act,
            rationale => $act eq 'drop'
                ? 'unused on this SiteName; AI unavailable so unused generic rows are offered as drop'
                : 'template/Maria fallback (AI unavailable)',
        });
        push @ai, $v if $v;
    }
    my $rows = $self->reconcile_draft($starting, \@ai);
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
        '_template_fallback', $why // 'AI unavailable');
    return {
        success  => @$rows ? 1 : 0,
        rows     => $rows,
        notes    => $why,
        source   => 'template_fallback',
        error    => @$rows ? undef : ($why || 'nothing to propose'),
    };
}

sub chart_rs {
    my ($self, $schema) = @_;
    return unless $schema;
    for my $name (qw(Chart Accounting::Chart)) {
        my $rs = eval { $schema->resultset($name) };
        return $rs if $rs;
    }
    return;
}

sub _notes_hash {
    my ($self, $notes) = @_;
    return {} unless defined $notes && $notes =~ /\S/;
    if ($notes =~ /^\s*\{/) {
        my $h = eval { $JSON->decode($notes) };
        return $h if ref $h eq 'HASH';
    }
    return { legacy_notes => $notes };
}

sub dropped_accnos_from_registry {
    my ($self, $maria, $sitename) = @_;
    return [] unless $maria && $sitename;
    my $reg = eval { $maria->resultset('SiteAccountingDb')->find({ sitename => $sitename }) };
    return [] unless $reg && defined $reg->notes;
    my $h = $self->_notes_hash($reg->notes);
    my $list = $h->{coa_ai} && ref $h->{coa_ai}{dropped_accnos} eq 'ARRAY'
        ? $h->{coa_ai}{dropped_accnos} : [];
    return [ grep { defined && length } @$list ];
}

sub persist_drop_list {
    my ($self, $c, $sitename, $dropped, $meta) = @_;
    my $reg = eval { $c->model('DBEncy')->resultset('SiteAccountingDb')->find({ sitename => $sitename }) };
    unless ($reg) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'persist_drop_list', "No site_accounting_dbs row for '$sitename'");
        return;
    }
    my $h = $self->_notes_hash($reg->notes);
    $h->{coa_ai} = {
        sitename       => $sitename,
        dropped_accnos => [ sort grep { defined && length } @{ $dropped || [] } ],
        entity_type    => $meta->{entity_type},
        base           => $meta->{base},
        overlays       => $meta->{overlays} || [],
    };
    eval { $reg->update({ notes => $JSON->encode($h) }) };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'persist_drop_list', "Failed to store drop list for '$sitename': $@");
    }
}

sub replace_with_industry {
    my ($self, $c, $sitename, $base_id, $overlays) = @_;
    $overlays ||= [];
    my $acct = Comserv::Model::AccountingDB->instance->schema_for_site($c, $sitename);
    return (0, [], "Cannot connect to PostgreSQL for '$sitename'") unless $acct;
    my $rs = $self->chart_rs($acct);
    return (0, [], 'PG schema has no Chart resultset') unless $rs;

    my $usage = $self->usage_by_accno($c, $sitename);
    my %keep;
    for my $row (@{ $self->template_rows($c, $base_id, $overlays) }) {
        $keep{ $row->{accno} } = $row if $row->{accno};
    }
    for my $m (@{ $self->maria_rows($c, $sitename) }) {
        next unless $m->{accno} && $usage->{ $m->{accno} }{in_use};
        $keep{ $m->{accno} } ||= $m;
    }

    my @dropped;
    my $removed = 0;
    for my $row ($rs->all) {
        my $accno = $row->accno;
        next if $keep{$accno};
        if ($usage->{$accno}{in_use}) {
            $keep{$accno} = { accno => $accno, description => $row->description };
            next;
        }
        eval { $row->delete };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
                'replace_with_industry', "Could not remove accno $accno for '$sitename': $@");
            return (0, \@dropped, "Could not remove $accno: $@");
        }
        push @dropped, $accno;
        $removed++;
    }

    my $coa = $self->coa;
    my ($added, @collisions) = $coa->seed_site_chart($c, $acct, $base_id, $overlays);
    $self->persist_drop_list($c, $sitename, \@dropped, {
        base     => $base_id,
        overlays => $overlays,
    });
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
        'replace_with_industry',
        "Site '$sitename' base=$base_id: added=$added removed=$removed dropped=["
        . join(',', @dropped) . "]");
    return ($added, \@dropped, undef);
}

sub commit_rows {
    my ($self, $c, $sitename, $rows, $meta) = @_;
    my $acct = Comserv::Model::AccountingDB->instance->schema_for_site($c, $sitename);
    unless ($acct) {
        return (0, "Cannot connect to PostgreSQL accounting DB for '$sitename'");
    }
    my $rs = $self->chart_rs($acct);
    unless ($rs) {
        return (0, 'PG schema has no Chart resultset');
    }
    my $added = 0;
    my @dropped;
    for my $row (@{ $rows || [] }) {
        my $v = $self->validate_row($row) or next;
        if ($v->{action} eq 'drop' && !$v->{in_use}) {
            push @dropped, $v->{accno};
            next;
        }
        eval {
            $rs->find_or_create({
                accno       => $v->{accno},
                description => $v->{description},
                charttype   => $v->{charttype},
                category    => $v->{category},
                link        => $v->{link} // '',
                gifi_accno  => $v->{gifi_accno} || undef,
                contra      => $v->{contra} ? 1 : 0,
            });
            $added++;
        };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
                'commit_rows', "Seed failed accno $v->{accno}: $@");
            return (0, "Seed failed for $v->{accno}: $@");
        }
    }
    $self->persist_drop_list($c, $sitename, \@dropped, $meta || {});
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
        'commit_rows', "Seeded $added reviewed chart rows for '$sitename'; dropped "
        . scalar(@dropped) . " unused");
    return ($added, undef);
}

# Apply an AI/template draft to PG: keep in-use, seed keep/add, delete unused drops.
sub apply_draft_to_pg {
    my ($self, $c, $sitename, $rows, $meta) = @_;
    my $acct = Comserv::Model::AccountingDB->instance->schema_for_site($c, $sitename);
    return (0, [], "Cannot connect to PostgreSQL for '$sitename'") unless $acct;
    my $rs = $self->chart_rs($acct);
    return (0, [], 'PG schema has no Chart resultset') unless $rs;
    my $usage = $self->usage_by_accno($c, $sitename);

    my %keep;
    my @dropped;
    for my $row (@{ $rows || [] }) {
        my $v = $self->validate_row($row) or next;
        if ($v->{in_use} || ($usage->{ $v->{accno} }{in_use})) {
            $v->{action} = 'keep' if ($v->{action} || '') eq 'drop';
            $keep{ $v->{accno} } = $v;
            next;
        }
        if (($v->{action} || '') eq 'drop') {
            push @dropped, $v->{accno};
            next;
        }
        $keep{ $v->{accno} } = $v;
    }

    my $removed = 0;
    for my $pg ($rs->all) {
        my $accno = $pg->accno;
        next if $keep{$accno};
        if ($usage->{$accno}{in_use}) {
            next;
        }
        eval { $pg->delete };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
                'apply_draft_to_pg', "Could not remove $accno: $@");
            return (0, \@dropped, "Could not remove $accno: $@");
        }
        push @dropped, $accno;
        $removed++;
    }

    my $added = 0;
    for my $v (values %keep) {
        eval {
            $rs->find_or_create({
                accno       => $v->{accno},
                description => $v->{description},
                charttype   => $v->{charttype} || 'A',
                category    => $v->{category},
                link        => $v->{link} // '',
                gifi_accno  => $v->{gifi_accno} || undef,
                contra      => $v->{contra} ? 1 : 0,
            });
            $added++;
        };
        if ($@) {
            return (0, \@dropped, "Seed failed for $v->{accno}: $@");
        }
    }
    $self->persist_drop_list($c, $sitename, \@dropped, $meta || {});
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
        'apply_draft_to_pg',
        "Site '$sitename': seeded=$added removed=$removed dropped=" . scalar(@dropped));
    return ($added, \@dropped, undef);
}

__PACKAGE__->meta->make_immutable;
1;
