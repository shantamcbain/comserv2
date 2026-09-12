package Comserv::Model::AI2::InvoiceCreate;
# ONE brain for entering invoices from Chat-with-AI (widget + editor).
#
# Reuses existing Inventory tables — NO new schema:
#   Accounting::InventorySupplierInvoice + lines  (AP / supplier bill)
#   Accounting::InventoryCustomerInvoice + lines  (AR / sales invoice)
#
# Always DRAFT. Never posts GL. Accounting reviews at
# /Inventory/invoice or /Inventory/sales then Posts there.
#
# Same intercept pattern as AI2::TodoCreate: natural language is handled
# on the server so free models cannot invent a fake form.

use Moose;
use namespace::autoclean -except => [qw(try catch finally)];
use Try::Tiny;
use JSON;
use DateTime;
use LWP::UserAgent;
use HTTP::Request;
use URI::Escape;
use Comserv::Util::Logging;

extends 'Catalyst::Model';

has 'logging' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Comserv::Util::Logging->instance },
);

sub sitename {
    my ($self, $c) = @_;
    # CSC is the paying entity: suppliers/bills are recorded under
    # sitename='CSC' and CSC recharges other sites (3d, BMaster, ...) for
    # their share. So the resolved site is authoritative for WRITES, and
    # match_supplier additionally falls back to CSC when the current site
    # has no suppliers — a session/stash mismatch must never produce a
    # false "No supplier found" (which previously triggered duplicate
    # auto-creation).
    for my $cand (
        $c->stash->{SiteName},
        $c->session->{SiteName},
        $c->session->{site_name},
        $c->stash->{site_name},
    ) {
        next unless defined $cand && $cand =~ /\S/;
        $cand =~ s/^\s+|\s+$//g;
        return $cand if length $cand;
    }
    return 'CSC';
}

sub _is_guest {
    my ($self, $c) = @_;
    my $u = $c->session->{username} || '';
    return 1 if !$u || lc($u) eq 'guest';
    return 0;
}

# Inventory invoice UI is admin-gated. Chat write uses the same bar:
# admin, accounting, or the Shanta override Inventory.pm already has.
sub _can_write_invoice {
    my ($self, $c) = @_;
    return 0 if $self->_is_guest($c);
    my $user = $c->session->{username} || '';
    return 1 if $user eq 'Shanta';
    my $roles = $c->session->{roles} // [];
    $roles = [ split /\s*,\s*/, $roles ] unless ref $roles eq 'ARRAY';
    return scalar grep { $_ =~ /^(admin|accounting|site_admin)$/i } @$roles;
}

sub _today { DateTime->now->ymd }

sub _norm {
    my ($s) = @_;
    $s = lc($s // '');
    $s =~ s/[^a-z0-9]+/ /g;
    $s =~ s/^\s+|\s+$//g;
    return $s;
}

# ---------------------------------------------------------------------------
# Intent: "enter this invoice …" — do NOT rely on [ACTION:].
# ---------------------------------------------------------------------------
sub detect_create_intent {
    my ($self, $prompt) = @_;
    return unless defined $prompt && $prompt =~ /\S/;
    my $p = $prompt;
    $p =~ s/^\s+|\s+$//g;

    return if $p =~ /^(how\s+(do\s+i|to)|what\s+is|explain|where\s+(is|do))\b/i;
    return if $p =~ /\b(list|show|find)\s+(my |the )?(invoices?|bills?)\b/i;
    return if $p =~ /\b(todos?|tasks?|to-dos?|to dos?)\b/i;

    my $has_doc = $p =~ /\b(invoice|bill|receipt)\b/i;
    my $has_verb = $p =~ /\b(enter|record|add|create|file|log|save|post)\b/i;
    # "I got a bill from X for $N" / pasted invoice text
    my $got_bill = $p =~ /\b(got|received|have)\s+(a\s+)?(invoice|bill|receipt)\b/i
                || $p =~ /\binvoice\s*#?\s*\S+/i;
    return unless $has_doc && ($has_verb || $got_bill);

    my $kind = 'supplier';
    if ($p =~ /\b(sales|customer|client|AR)\b/i
        && $p !~ /\b(supplier|vendor|AP|purchase)\b/i) {
        $kind = 'customer';
    }
    if ($p =~ /\b(supplier|vendor|AP|purchase)\s+(invoice|bill)\b/i
        || $p =~ /\b(bill from|invoice from)\b/i) {
        $kind = 'supplier';
    }

    my $invoice_number = '';
    if ($p =~ /\binvoice\s*(?:number|no\.?|#)\s*[:#]?\s*([A-Za-z0-9][\w\-\/]{1,40})/i) {
        $invoice_number = $1;
    }
    elsif ($p =~ /\b(?:inv|invoice)\s*#\s*([A-Za-z0-9][\w\-\/]{1,40})/i) {
        $invoice_number = $1;
    }

    my $invoice_date = '';
    if ($p =~ /\b(\d{4}-\d{2}-\d{2})\b/) {
        $invoice_date = $1;
    }
    elsif ($p =~ /\b(today)\b/i) {
        $invoice_date = _today();
    }
    # "Paid September 10, 2026" / "dated Sep 10 2026" — a plain Month-DD-YYYY
    # date is the most common form on a pasted receipt, so parse it here.
    elsif ($p =~ /\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})\b/i) {
        my %mon = (jan=>1, feb=>2, mar=>3, apr=>4, may=>5, jun=>6,
                   jul=>7, aug=>8, sep=>9, oct=>10, nov=>11, dec=>12);
        my $m = $mon{ lc substr($1, 0, 3) } || 1;
        my $d = $2; my $y = $3;
        $invoice_date = sprintf('%04d-%02d-%02d', $y, $m, $d);
    }

    my $amount;
    # Currency symbols: $, EUR sign, GBP sign. Written as escapes (not a
    # literal char class) because the source has no "use utf8" and a raw
    # multi-byte class makes Perl interpolate $ as a variable.
    # Allow an optional spacing between symbol and digits ("US$ 50.00").
    my $NUM = qr/\d[\d,]*(?:\.\d{1,2})?/;
    if ($p =~ /(?:\$|\xe2\x82\xac|\xc2\xa3)\s*($NUM)/) {
        ($amount = $1) =~ s/,//g;
    }
    elsif ($p =~ /\b(?:total|amount|for)\s+($NUM)\s*(?:cad|usd|eur|gbp|dollars?)?\b/i) {
        ($amount = $1) =~ s/,//g;
    }
    my $tax;
    if ($p =~ /\b(?:tax|gst|hst|pst)\s*:?\s*\$?\s*(\d[\d,]*(?:\.\d{1,2})?)/i) {
        ($tax = $1) =~ s/,//g;
    }

    # Currency. The schema defaults currency to 'CAD', but most pasted
    # receipts (Stripe/OpenRouter etc) are USD — hardcoding CAD silently
    # mis-states the amount. Detect an explicit code/symbol; default CAD.
    # NOTE: do NOT anchor symbol forms with \b — "$" is not a word character,
    # so /\bUS\$/ never matches. Match the symbol forms first, longest-first.
    my $currency = 'CAD';
    # NOTE: no "use utf8" here, so €/£ arrive as raw UTF-8 BYTES — match the
    # byte sequences, not \x{20AC} (which expects a decoded codepoint).
    # Also allow the marker to trail the amount ("$50.00 US$").
    if    ($p =~ /US\s*\$/i || $p =~ /\bUSD\b/i)                 { $currency = 'USD'; }
    elsif ($p =~ /CA\s*\$/i || $p =~ /C\s*\$/i || $p =~ /\bCAD\b/i) { $currency = 'CAD'; }
    elsif ($p =~ /\xe2\x82\xac/ || $p =~ /\bEUR\b/i)             { $currency = 'EUR'; }
    elsif ($p =~ /\xc2\xa3/     || $p =~ /\bGBP\b/i)             { $currency = 'GBP'; }

    my $party = '';
    if ($kind eq 'supplier') {
        if ($p =~ /\b(?:from|supplier|vendor)\s+([A-Za-z][A-Za-z0-9 .,&'\-]{1,60}?)(?=\s+(?:for|invoice|bill|dated|on\s+\d|\$)|$)/i) {
            $party = $1;
        }
    }
    else {
        if ($p =~ /\b(?:for|customer|client|to)\s+([A-Za-z][A-Za-z0-9 .,&'\-]{1,60}?)(?=\s+(?:for|invoice|dated|on\s+\d|\$)|$)/i) {
            $party = $1;
        }
    }
    $party =~ s/^\s+|\s+$//g;
    $party =~ s/\s+(invoice|bill|receipt)$//i;

    my $description = $p;
    $description =~ s/\s+/ /g;

    # ── Receipt vs bill ────────────────────────────────────────────────────
    # inventory_supplier_invoices is an AP BILL (has due_date/ap_account_id,
    # lifecycle draft -> posted -> paid) — i.e. money we still OWE. A card
    # receipt ("Paid", "Amount paid", "Visa -3627", "Receipt #") is money
    # already PAID, often for prepaid credits. Writing that as a draft bill
    # states the opposite of what happened, so detect it and make the caller
    # ASK which kind the user wants instead of guessing.
    my $looks_paid = 0;
    $looks_paid = 1 if $p =~ /\b(?:amount\s+paid|paid\s+(?:on|in\s+full)?)\b/i;
    $looks_paid = 1 if $p =~ /\b(?:visa|mastercard|amex|american\s+express)\b/i
                    && $p =~ /[-*]?\s*\d{4}\b/;
    $looks_paid = 1 if $p =~ /\breceipt\s*(?:#|number|no\.?)\b/i;
    $looks_paid = 1 if $p =~ /\b(?:payment\s+method|paid)\b/i && $p =~ /\b(?:receipt|credits?)\b/i;

    # Prepaid credits (rather than goods/services received).
    my $looks_prepaid = ($p =~ /\b(?:credits?|account\s+(?:balance|refill)|top[- ]?up|prepaid)\b/i) ? 1 : 0;

    # Card last-4, for the notes field.
    my $card = '';
    if ($p =~ /\b(visa|mastercard|amex|american\s+express)\b[^0-9]{0,12}(\d{4})/i) {
        $card = ucfirst(lc $1) . " -" . $2;
    }

    return {
        kind            => $kind,
        looks_paid      => $looks_paid,
        looks_prepaid   => $looks_prepaid,
        payment_card    => $card,
        invoice_number  => $invoice_number,
        invoice_date    => $invoice_date,
        amount          => $amount,
        tax_amount      => $tax,
        currency        => $currency,
        party           => $party,
        description     => $description,
        notes           => "Entered from Chat-with-AI:\n$p",
    };
}

sub _schema {
    my ($self, $c) = @_;
    return eval { $c->model('DBEncy')->schema } || eval { $c->model('DBEncy') };
}

sub list_suppliers {
    my ($self, $c, $sitename) = @_;
    $sitename ||= $self->sitename($c);
    my $schema = $self->_schema($c) or return [];
    my @out;
    eval {
        my $rs = $schema->resultset('Accounting::InventorySupplier')->search(
            { sitename => $sitename, status => 'active' },
            { order_by => 'name', rows => 80 },
        );
        while (my $s = $rs->next) {
            push @out, { id => 0 + $s->id, name => $s->name // '' };
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'list_suppliers', "Failed: $@");
    }
    return \@out;
}

sub rank_parties {
    my ($self, $query, $parties) = @_;
    $parties ||= [];
    my $qn = _norm($query);
    return [] unless length $qn && ref $parties eq 'ARRAY';
    my @out;
    for my $p (@$parties) {
        next unless ref $p eq 'HASH';
        my $nn = _norm($p->{name});
        my $score = 0;
        $score += 100 if $nn eq $qn;
        $score += 70  if length $nn && index($nn, $qn) == 0;
        $score += 45  if length $nn && index($nn, $qn) >= 0;
        $score += 45  if length $qn && index($qn, $nn) >= 0 && length $nn > 2;
        next unless $score > 0;
        push @out, { %$p, score => $score };
    }
    return [ sort { $b->{score} <=> $a->{score} || ($a->{id}||0) <=> ($b->{id}||0) } @out ];
}

sub match_supplier {
    my ($self, $c, %args) = @_;
    my $sitename = $args{sitename} || $self->sitename($c);
    my $out = { status => 'none', sitename => $sitename, supplier => undef, candidates => [] };
    my $pid = $args{supplier_id};
    my $schema = $self->_schema($c);
    if (defined $pid && $pid =~ /^\d+$/ && $pid > 0 && $schema) {
        my $row = eval { $schema->resultset('Accounting::InventorySupplier')->find($pid) };
        if ($row) {
            $out->{status}   = 'exact';
            $out->{supplier} = { id => 0 + $row->id, name => $row->name // '' };
            return $out;
        }
    }
    my $q = $args{party} || $args{supplier_name} || '';
    $q =~ s/^\s+|\s+$//g;
    return $out unless length $q;

    # CSC is the paying entity and owns the supplier/vendor records; other
    # sites (3d, BMaster...) are recharged for their share. If the current
    # site returns no suppliers at all, fall back to CSC rather than
    # reporting "not found" — that false negative previously triggered
    # auto-creation of duplicate suppliers.
    my $pool = $self->list_suppliers($c, $sitename);
    if (!@$pool && $sitename ne 'CSC') {
        my $csc = $self->list_suppliers($c, 'CSC');
        if (@$csc) {
            $pool = $csc;
            $out->{sitename_used} = 'CSC';
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
                'match_supplier', "no suppliers on '$sitename'; fell back to CSC");
        }
    }

    my $ranked = $self->rank_parties($q, $pool);
    return $out unless @$ranked;
    my $top = $ranked->[0];
    my $second = $ranked->[1];
    if ($top->{score} >= 70 && (!$second || ($top->{score} - $second->{score}) >= 12)) {
        $out->{status}     = 'exact';
        $out->{supplier}   = $top;
        $out->{candidates} = [ splice @$ranked, 0, 5 ];
        return $out;
    }
    if ($top->{score} >= 18) {
        $out->{status}     = 'ambiguous';
        $out->{candidates} = [ splice @$ranked, 0, 8 ];
        return $out;
    }
    $out->{candidates} = [ splice @$ranked, 0, 5 ];
    return $out;
}

# Short-circuit /ai2/chat when the user asked to enter an invoice.
sub try_chat_create {
    my ($self, $c, %args) = @_;
    my $intent = $self->detect_create_intent($args{prompt} // '') or return;
    if ($self->_is_guest($c)) {
        return {
            handled        => 1,
            success        => 1,
            response       => 'Log in to enter an invoice from chat.',
            model          => '(invoice-create)',
            provider       => 'ai2-invoice',
            invoice_action => { success => JSON::false, error => 'Login required' },
        };
    }
    unless ($self->_can_write_invoice($c)) {
        return {
            handled        => 1,
            success        => 1,
            response       => 'Entering invoices needs an admin or accounting role. Enable the Accounting feature in CSC Membership Settings if it is not on for this site, then retry.',
            model          => '(invoice-create)',
            provider       => 'ai2-invoice',
            invoice_action => { success => JSON::false, error => 'Permission denied' },
        };
    }
    my $created = eval { $self->create_from_params($c, $intent) };
    if ($@ || !$created) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'try_chat_create', "create_from_params threw: $@");
        $created = { success => JSON::false, error => 'Invoice create failed' };
    }
    my $msg = $created->{message} || $created->{error} || 'Invoice request processed.';
    $msg .= ' ' . $created->{invoice_url} if $created->{success} && $created->{invoice_url};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'try_chat_create',
        'Chat invoice intent: ' . ($created->{success} ? "draft #$created->{invoice_id}" : ($created->{error} || 'no-create')));
    return {
        handled        => 1,
        success        => 1,
        response       => $msg,
        model          => '(invoice-create)',
        provider       => 'ai2-invoice',
        invoice_action => $created,
    };
}

sub chat_contract {
    my ($self, $c) = @_;
    return '' if $self->_is_guest($c);
    return '' unless $self->_can_write_invoice($c);
    my $sitename = $self->sitename($c);
    my $suppliers = $self->list_suppliers($c, $sitename);
    my $list = '';
    if (@$suppliers) {
        $list = "Active suppliers on $sitename (use id or name - do NOT invent ids):\n";
        for my $s (@$suppliers[0 .. ($#$suppliers < 19 ? $#$suppliers : 19)]) {
            $list .= sprintf("  #%s %s\n", $s->{id}, $s->{name} || '(unnamed)');
        }
    }
    else {
        $list = "No active suppliers listed for $sitename yet. New suppliers are auto-created when you enter an invoice — just name the supplier. Web lookup may add contact info.\n";
    }
    return <<"END";
INVOICE ENTRY (SiteName=$sitename) — DRAFT ONLY, never post GL from chat:
When the user pastes or asks to enter/record/add an invoice or bill:
1. Decide kind: supplier/AP ("bill from", "supplier invoice") vs customer/AR ("sales invoice", "invoice for customer"). Default supplier.
2. Extract invoice_number, invoice_date (YYYY-MM-DD), amount, tax_amount, party name, optional line description.
3. Emit exactly one ACTION:
[ACTION: {"action":"create_invoice","params":{"kind":"supplier","supplier_name":"...","invoice_number":"...","invoice_date":"YYYY-MM-DD","amount":0,"tax_amount":0,"description":"..."}}]
For a sales invoice use kind=customer and customer_name instead of supplier_name.
4. The server creates a DRAFT on this SiteName. Accounting posts later at /Inventory/invoice (AP) or /Inventory/sales (AR).
5. If supplier is missing or ambiguous the server auto-creates it from the party name, then creates the draft invoice. Do not invent a supplier_id manually.
6. Do not emit create_invoice unless the user asked to enter/record an invoice.

$list
END
}

sub create_from_params {
    my ($self, $c, $params) = @_;
    $params ||= {};
    my $sitename = $self->sitename($c);
    my $user     = $c->session->{username} || 'ai';
    my $kind     = ($params->{kind} || 'supplier') eq 'customer' ? 'customer' : 'supplier';
    my $today    = $self->_today;
    my $date     = $params->{invoice_date} || '';
    $date = $today unless $date =~ /^\d{4}-\d{2}-\d{2}$/;
    my $amount   = $params->{amount};
    $amount = undef unless defined $amount && $amount =~ /^\d+(\.\d{1,2})?$/;
    my $tax      = $params->{tax_amount} || 0;
    $tax = 0 unless $tax =~ /^\d+(\.\d{1,2})?$/;

    unless (defined $amount && $amount > 0) {
        return {
            success      => JSON::false,
            need_clarify => JSON::true,
            field        => 'amount',
            draft        => $params,
            sitename     => $sitename,
            message      => 'I can enter the invoice as a draft, but I need the total amount (e.g. $45.20).',
        };
    }

    # ── Receipt/payment: ASK before writing ────────────────────────────────
    # A card receipt is money already paid, NOT a bill we owe. Writing it as
    # a draft AP invoice states the opposite, so stop and let the user choose.
    # They can force it by saying "bill"/"invoice" or passing record_kind.
    # NOTE: this runs BEFORE the DB handle is needed — asking a question must
    # not depend on the database being up.
    my $force = lc($params->{record_kind} || '');
    if ($params->{looks_paid} && $force ne 'bill' && $force ne 'prepaid' && $force ne 'paid') {
        my $card = $params->{payment_card} ? " (card $params->{payment_card})" : '';
        return {
            success      => JSON::false,
            need_kind    => JSON::true,
            sitename     => $sitename,
            draft        => $params,
            options      => [
                { id => 'bill',    label => 'Unpaid bill (AP) — record as a draft invoice we owe' },
                { id => 'paid',    label => 'Already paid — record as a paid AP invoice' },
                { id => 'prepaid', label => 'Prepaid credits — money paid up front, drawn down later' },
            ],
            message      => "This looks like a card RECEIPT - money already paid$card, not a bill we owe. "
                          . "Which should I record it as? (reply: bill / paid / prepaid)",
        };
    }

    # User picked "paid" — same AP invoice but settled, not a draft.
    my $is_paid = ($force eq 'paid') ? 1 : 0;

    my $schema = $self->_schema($c)
        or return { success => JSON::false, error => 'Database not available' };
    if ($kind eq 'customer') {
        return $self->_insert_customer($c, $schema, {
            sitename       => $sitename,
            user           => $user,
            today          => $today,
            invoice_date   => $date,
            amount         => $amount,
            tax_amount     => $tax,
            customer_name  => $params->{customer_name} || $params->{party} || '',
            invoice_number => $params->{invoice_number} || '',
            description    => $params->{description} || '',
            notes          => $params->{notes} || '',
        });
    }

    my $match = $self->match_supplier($c,
        sitename     => $sitename,
        supplier_id  => $params->{supplier_id},
        supplier_name=> $params->{supplier_name} || $params->{party} || '',
        party        => $params->{party} || $params->{supplier_name} || '',
    );
    if ($match->{status} eq 'ambiguous') {
        return {
            success    => JSON::false,
            need_pick  => JSON::true,
            sitename   => $sitename,
            draft      => $params,
            candidates => $match->{candidates} || [],
            message    => "Several $sitename suppliers could fit. Which one?",
        };
    }
    unless ($match->{supplier} && $match->{supplier}{id}) {
        # ── Diagnostic ─────────────────────────────────────────────────────
        # We cannot reach the DB from the agent, and logs may be absent, so
        # surface the ACTUAL values in the chat reply: the sitename we queried,
        # the party we looked for, and the suppliers we could see. That makes
        # the next test self-diagnosing instead of another guess.
        my $seen  = $self->list_suppliers($c, $sitename);
        my $names = @$seen
            ? join(', ', map { $_->{name} } @{$seen}[0 .. ($#$seen > 7 ? 7 : $#$seen)])
            : '(none)';
        my $diag = " [diag: sitename='$sitename', party='"
                 . ($params->{supplier_name} || $params->{party} || '')
                 . "', suppliers_visible=" . scalar(@$seen) . ": $names]";
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'match_supplier', "NO MATCH$diag");

        # Auto-create the supplier from the parsed party name instead of
        # just asking the user to go to /Inventory manually.
        my $auto;
        # Create the supplier and the invoice in ONE transaction. Previously
        # the supplier was committed first, so a later invoice failure (e.g.
        # the varchar(255) description abort) left an ORPHAN supplier each
        # retry — that is how duplicate 'OpenRouter, Inc' rows appeared.
        my $ok = eval {
            $schema->txn_do(sub {
                $auto = $self->_auto_create_supplier($c, $schema, {
                    sitename => $sitename,
                    user     => $user,
                    name     => $params->{supplier_name} || $params->{party} || '',
                    notes    => "Auto-created from Chat-with-AI invoice entry.",
                });
                die "supplier create failed\n" unless $auto && $auto->{id};
            });
            1;
        };
        if ($ok && $auto && $auto->{id}) {
            $match = { status => 'exact', supplier => { id => $auto->{id}, name => $auto->{name} || '' } };
        }
        else {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
                'auto_create_supplier', "rolled back: " . ($@ || 'unknown'));
            return {
                success       => JSON::false,
                need_supplier => JSON::true,
                sitename      => $sitename,
                draft         => $params,
                candidates    => $match->{candidates} || [],
                message       => "No supplier found - web lookup may be needed." . $diag,
            };
        }
    }

    # Existing supplier: top up any BLANK contact fields from the web before
    # creating the invoice. Only fills gaps — never overwrites what's there.
    my $enriched = eval {
        $self->_enrich_existing_supplier($c, $schema,
            $match->{supplier}{id}, $match->{supplier}{name});
    } || { filled => {} };

    my $res = $self->_insert_supplier($c, $schema, {
        sitename       => $sitename,
        user           => $user,
        today          => $today,
        invoice_date   => $date,
        amount         => $amount,
        tax_amount     => $tax,
        currency       => $params->{currency} || 'CAD',
        is_paid        => $is_paid,
        payment_card   => $params->{payment_card} || '',
        supplier       => $match->{supplier},
        invoice_number => $params->{invoice_number} || '',
        description    => $params->{description} || $params->{notes} || '',
        notes          => $params->{notes} || '',
    });

    # Tell the user what we filled in so they can sanity-check it.
    if ($res->{success} && ref $enriched eq 'HASH' && %{ $enriched->{filled} || {} }) {
        my @kv = map { "$_=" . $enriched->{filled}{$_} }
                 sort keys %{ $enriched->{filled} };
        $res->{supplier_enriched} = [ sort keys %{ $enriched->{filled} } ];
        $res->{message} .= " I also filled in missing supplier contact info ("
                        .  join(', ', @kv) . ") - please verify it.";
    }
    return $res;
}

sub _auto_create_supplier {
    my ($self, $c, $schema, $args) = @_;
    my $name = $args->{name} || '';
    $name =~ s/^\s+|\s+$//g;
    return undef unless length $name >= 2;

    my $sitename = $args->{sitename} || $self->sitename($c);
    my $user     = $args->{user} || 'ai';
    my $now      = DateTime->now->strftime('%Y-%m-%d %H:%M:%S');

    # Check for an existing supplier with this name before creating
    my $existing;
    eval {
        $existing = $schema->resultset('Accounting::InventorySupplier')->search({
            sitename => $sitename,
            name     => $name,
        })->first;
    };
    if ($existing) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto_create_supplier',
            "Supplier '$name' already exists on $sitename");
        return { id => 0 + $existing->id, name => $existing->name // '' };
    }

    # Attempt web lookup to enrich supplier data
    my $enriched = $self->_web_lookup_supplier($c, $name);

    my $supplier;
    eval {
        $supplier = $schema->resultset('Accounting::InventorySupplier')->create({
            sitename     => $sitename,
            name         => $name,
            contact_name => $enriched->{contact_name} || undef,
            email        => $enriched->{email} || undef,
            phone        => $enriched->{phone} || undef,
            address      => $enriched->{address} || undef,
            website      => $enriched->{website} || undef,
            status       => 'active',
            notes        => $args->{notes} || 'Auto-created from Chat-with-AI invoice entry.',
            created_by   => $user,
            created_at   => $now,
            updated_at   => $now,
        });
    };
    if ($@ || !$supplier) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'auto_create_supplier', "Failed: $@");
        return undef;
    }

    # If web lookup returned extra fields not in the initial insert, update
    if ($enriched && ($enriched->{contact_name} || $enriched->{email} || $enriched->{phone} || $enriched->{address} || $enriched->{website})) {
        my %update;
        $update{contact_name} = $enriched->{contact_name} if $enriched->{contact_name};
        $update{email}        = $enriched->{email}        if $enriched->{email};
        $update{phone}        = $enriched->{phone}        if $enriched->{phone};
        $update{address}      = $enriched->{address}      if $enriched->{address};
        $update{website}      = $enriched->{website}      if $enriched->{website};
        eval { $supplier->update(\%update) };
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto_create_supplier',
        "Auto-created supplier #" . $supplier->id . " '$name' on $sitename" . ($enriched ? ' (web-enriched)' : ''));
    return { id => 0 + $supplier->id, name => $supplier->name // '' };
}

# Fill in only the BLANK fields of an existing supplier from the web lookup.
# Never overwrites data the user already has — this is an enrichment, not a
# correction, so a wrong phone we scraped can't clobber a good one.
#
# Returns { checked => [...], filled => { field => value } } or undef.
sub _enrich_existing_supplier {
    my ($self, $c, $schema, $id, $name) = @_;
    return undef unless $id && $id =~ /^\d+$/;

    my $row = eval { $schema->resultset('Accounting::InventorySupplier')->find($id) };
    return undef unless $row;

    # Which contact fields are still empty?
    my @want;
    for my $f (qw(contact_name email phone address website)) {
        my $v = eval { $row->$f } // '';
        $v = '' unless defined $v;
        $v =~ s/^\s+|\s+$//g;
        push @want, $f if $v eq '' || $v eq '-';   # '-' is the list placeholder
    }
    return { checked => \@want, filled => {} } unless @want;

    my $info = $self->_web_lookup_supplier($c, $name);
    return { checked => \@want, filled => {} } unless $info;

    my %filled;
    my %upd;
    for my $f (@want) {
        my $val = $info->{$f};
        next unless defined $val && length $val;
        $upd{$f}   = $val;
        $filled{$f} = $val;
    }
    if (%upd) {
        $upd{updated_at} = DateTime->now->strftime('%Y-%m-%d %H:%M:%S');
        eval {
            $schema->txn_do(sub { $row->update(\%upd) });
        };
        if ($@) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
                'enrich_supplier', "update failed for #$id: $@");
            return { checked => \@want, filled => {} };
        }
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
            'enrich_supplier', "supplier #$id filled: " . join(',', sort keys %filled));
    }
    return { checked => \@want, filled => \%filled };
}

# Look up a supplier's public contact details.
#
# Primary: the self-hosted SearXNG service (root/config/services.json ->
# "search"). NOTE the call shape matters: SearXNG only honours format=json on
# a FORM-ENCODED request. POSTing a JSON body (what this sub originally did)
# silently returns HTML, which then fails to parse and yields no data — that
# is why the supplier was created with a name and nothing else.
#
# Fallback: DuckDuckGo HTML scrape (free, no key). The DDG *Instant Answer*
# API is NOT suitable here — it returns empty for company lookups
# (AbstractText "" / RelatedTopics []), verified 2026-09-10.
#
# Returns { email, phone, website, address, raw_snippets } or undef.
sub _web_lookup_supplier {
    my ($self, $c, $name) = @_;
    return undef unless defined $name && length($name) >= 2;

    my $q  = "$name company contact email phone address website";
    my $ua = LWP::UserAgent->new(timeout => 12);
    $ua->agent('Comserv/2.0');

    my @snippets = $self->_searxng_snippets($c, $ua, $q);
    if (!@snippets) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
            'web_lookup_supplier', "SearXNG returned nothing for '$name'; trying DDG fallback");
        @snippets = $self->_ddg_snippets($c, $ua, $q);
    }

    return undef unless @snippets;

    my %result;
    my $blob = join(' ', @snippets);

    # Email — prefer one on the vendor's own domain when we can infer it.
    if ($blob =~ /([\w.+-]+@[\w.-]+\.\w{2,})/) {
        $result{email} = $1;
    }
    # Phone — require a plausible digit count AND a phone-ish separator or
    # leading +. A bare 10-digit run (e.g. "0002073423" from a tracking ID)
    # is rejected, because a wrong number in the form is worse than none.
    {
        my $best;
        while ($blob =~ /(\+?\d[\d\s().-]{7,22}\d)/g) {
            my $raw = $1;
            my $digits = $raw;
            $digits =~ s/\D//g;
            next if length($digits) < 10 || length($digits) > 15;
            next if $digits =~ /^0{3,}/;                 # 0002073423 style junk
            # Must look like a phone: leading +, or separators, or a NANP form
            next unless $raw =~ /^\+/ || $raw =~ /[\s().-]/;
            $best = $raw;
            last if $raw =~ /^\+/;                        # prefer +1-xxx form
        }
        if ($best) {
            ($result{phone} = $best) =~ s/\s+/ /g;
            $result{phone} =~ s/^\s+|\s+$//g;
        }
    }
    # Website — first http(s) link that isn't a search engine/social.
    for my $s (@snippets) {
        while ($s =~ m{(https?://[^\s"'>]+)}g) {
            my $u = $1;
            $u =~ s/[.,;)]+$//;
            next if $u =~ /(duckduckgo|google|bing|facebook|twitter|linkedin|wikipedia|youtube|instagram)\./i;
            $result{website} = $u;
            last;
        }
        last if $result{website};
    }
    $result{raw_snippets} = [ @snippets[0 .. ($#snippets > 2 ? 2 : $#snippets)] ];

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
        'web_lookup_supplier', sprintf(
            "lookup '%s' -> email=%s phone=%s website=%s (%d snippets)",
            $name,
            $result{email}    ? 'yes' : 'no',
            $result{phone}    ? 'yes' : 'no',
            $result{website}  ? 'yes' : 'no',
            scalar @snippets));

    return \%result;
}

# Query the self-hosted SearXNG. MUST be form-encoded (GET or POST with
# application/x-www-form-urlencoded) — a JSON body returns HTML.
sub _searxng_snippets {
    my ($self, $c, $ua, $q) = @_;
    my $cfg = eval {
        require Comserv::Model::AI2::Search;
        Comserv::Model::AI2::Search->_cfg($c);
    } || {};
    return () unless $cfg && $cfg->{enabled} && $cfg->{url};

    my $base = $cfg->{url};
    $base =~ s{/+$}{};
    my $url = "$base/search?q=" . uri_escape($q) . "&format=json&language=en";

    my @out;
    eval {
        my $req  = HTTP::Request->new(GET => $url);
        $req->header('Accept' => 'application/json');
        my $resp = $ua->request($req);
        if ($resp->is_success) {
            my $data = eval { JSON::decode_json($resp->decoded_content) };
            if ($data && ref $data eq 'HASH') {
                for my $r (@{ $data->{results} || [] }) {
                    next unless ref $r eq 'HASH';
                    my $t = ($r->{title}   // '') . ' ' . ($r->{content} // '');
                    $t =~ s/\s+/ /g;
                    push @out, $t if length $t > 5;
                }
            }
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'searxng_snippets', "SearXNG query failed: $@");
    }
    return @out;
}

# Free fallback: DDG HTML endpoint (no key). The Instant Answer JSON API is
# deliberately NOT used — it returns empty for company lookups.
sub _ddg_snippets {
    my ($self, $c, $ua, $q) = @_;
    my @out;
    eval {
        my $url  = 'https://html.duckduckgo.com/html/?q=' . uri_escape($q);
        my $req  = HTTP::Request->new(GET => $url);
        $req->header('Accept' => 'text/html');
        my $resp = $ua->request($req);
        if ($resp->is_success) {
            my $html = $resp->decoded_content // '';
            # result snippets
            while ($html =~ m{class="result__snippet"[^>]*>(.*?)</a>}gis) {
                my $t = $1;
                $t =~ s/<[^>]+>//g;
                $t =~ s/&nbsp;/ /g; $t =~ s/&amp;/&/g; $t =~ s/&#x27;/'/g;
                $t =~ s/\s+/ /g;
                push @out, $t if length $t > 5;
            }
            # titles if no snippets matched
            if (!@out) {
                while ($html =~ m{class="result__a"[^>]*>(.*?)</a>}gis) {
                    my $t = $1;
                    $t =~ s/<[^>]+>//g;
                    $t =~ s/\s+/ /g;
                    push @out, $t if length $t > 5;
                }
            }
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'ddg_snippets', "DDG fallback failed: $@");
    }
    return @out;
}

# inventory_supplier_invoice_lines.description is varchar(255). A pasted
# receipt is routinely longer than that, which aborts the whole insert with
# "Data too long for column 'description'". Clamp to the column width (prefer
# a word boundary) so a long paste degrades to a short line label instead of
# failing the invoice. Mirrors AI2::TodoCreate::normalize_subject_description.
sub _clamp_description {
    my ($self, $text) = @_;
    $text = '' unless defined $text;
    $text =~ s/\s+/ /g;
    $text =~ s/^\s+|\s+$//g;
    return 'Entered from chat' unless length $text;
    return $text if length($text) <= 255;
    my $cut = substr($text, 0, 255);
    # Prefer trimming back to the last space so we don't split a word.
    my $sp = rindex($cut, ' ');
    $cut = substr($cut, 0, $sp) if $sp > 200;
    $cut =~ s/[\s,;:\-]+$//;
    return $cut;
}

sub _insert_supplier {
    my ($self, $c, $schema, $args) = @_;
    my $now = DateTime->now->strftime('%Y-%m-%d %H:%M:%S');
    my $line_amt = sprintf('%.2f', $args->{amount} - ($args->{tax_amount} || 0));
    $line_amt = $args->{amount} if $line_amt <= 0;
    my $invoice;
    eval {
        $schema->txn_do(sub {
            $invoice = $schema->resultset('Accounting::InventorySupplierInvoice')->create({
                sitename        => $args->{sitename},
                supplier_id     => $args->{supplier}{id},
                invoice_number  => $args->{invoice_number} || undef,
                invoice_date    => $args->{invoice_date},
                tax_amount      => $args->{tax_amount} || 0,
                # 'draft' = unpaid bill we owe. A settled card payment is
                # recorded 'paid' instead — see the receipt/payment guard in
                # create_from_params.
                status          => ($args->{is_paid} ? 'paid' : 'draft'),
                notes           => ($args->{payment_card} && $args->{is_paid})
                                    ? "Paid by card: $args->{payment_card}\n" . ($args->{notes} || '')
                                    : $args->{notes},
                created_by      => $args->{user},
                created_at      => $now,
                updated_at      => $now,
                currency        => ($args->{currency} || 'CAD'),
            });
            $invoice->create_related('lines', {
                description => $self->_clamp_description($args->{description}),
                quantity    => 1,
                unit_cost   => $line_amt,
                line_total  => $line_amt,
            });
            my $grand = $line_amt + ($args->{tax_amount} || 0);
            $invoice->update({ total_amount => $grand });
        });
    };
    if ($@ || !$invoice) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'insert_supplier', "create failed: $@");
        return { success => JSON::false, error => 'Invoice creation failed' };
    }
    my $id = $invoice->id;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'insert_supplier',
        "Draft AP invoice #$id sitename=$args->{sitename} supplier=$args->{supplier}{id} by=$args->{user}");
    return {
        success        => JSON::true,
        kind           => 'supplier',
        invoice_id     => 0 + $id,
        invoice_url    => "/Inventory/invoice/view/$id",
        supplier_id    => 0 + $args->{supplier}{id},
        supplier_name  => $args->{supplier}{name},
        sitename       => $args->{sitename},
        status         => 'draft',
        message        => "Draft supplier invoice #$id saved for $args->{supplier}{name} on $args->{sitename}. Accounting still needs to review and Post - chat does not post the GL.",
    };
}

sub _insert_customer {
    my ($self, $c, $schema, $args) = @_;
    my $name = $args->{customer_name} || '';
    $name =~ s/^\s+|\s+$//g;
    unless (length $name >= 2) {
        return {
            success      => JSON::false,
            need_clarify => JSON::true,
            field        => 'customer_name',
            draft        => $args,
            sitename     => $args->{sitename},
            message      => 'Sales invoice needs a customer name.',
        };
    }
    my $now = DateTime->now->strftime('%Y-%m-%d %H:%M:%S');
    my $line_amt = sprintf('%.2f', $args->{amount} - ($args->{tax_amount} || 0));
    $line_amt = $args->{amount} if $line_amt <= 0;
    my $inv_num = $args->{invoice_number};
    unless ($inv_num) {
        $inv_num = 'CHAT-' . $args->{today} . '-' . int(rand(9000)+1000);
    }
    my $invoice;
    eval {
        $schema->txn_do(sub {
            $invoice = $schema->resultset('Accounting::InventoryCustomerInvoice')->create({
                sitename       => $args->{sitename},
                customer_name  => $name,
                invoice_number => $inv_num,
                invoice_date   => $args->{invoice_date},
                tax_amount     => $args->{tax_amount} || 0,
                status         => 'draft',
                notes          => $args->{notes},
                created_by     => $args->{user},
                created_at     => $now,
                updated_at     => $now,
            });
            $invoice->create_related('lines', {
                description => $self->_clamp_description($args->{description}),
                quantity    => 1,
                unit_price  => $line_amt,
                line_total  => $line_amt,
            });
            $invoice->update({ total_amount => $line_amt + ($args->{tax_amount} || 0) });
        });
    };
    if ($@ || !$invoice) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'insert_customer', "create failed: $@");
        return { success => JSON::false, error => 'Invoice creation failed' };
    }
    my $id = $invoice->id;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'insert_customer',
        "Draft AR invoice #$id sitename=$args->{sitename} customer=$name by=$args->{user}");
    return {
        success        => JSON::true,
        kind           => 'customer',
        invoice_id     => 0 + $id,
        invoice_url    => "/Inventory/sales/view/$id",
        customer_name  => $name,
        sitename       => $args->{sitename},
        status         => 'draft',
        message        => "Draft sales invoice #$id saved for $name on $args->{sitename}. Accounting still needs to review and Post - chat does not post the GL.",
    };
}

# Resolve a supplier name to its numeric id for pre-filling
# <select name="supplier_id"> on /Inventory/invoice/new. Returns the id the
# form needs; never invents one.
sub perform_resolve_supplier {
    my ($self, $c, $params) = @_;
    $params ||= {};

    my $name = $params->{name} || $params->{party} || $params->{supplier_name} || '';
    $name =~ s/^\s+|\s+$//g;

    unless (length $name >= 2) {
        $self->write_json($c, 400, { success => JSON::false, error => 'name required' });
        return;
    }

    my $sitename = $self->sitename($c);
    my $match    = $self->match_supplier($c,
        sitename      => $sitename,
        supplier_name => $name,
        party         => $name,
        supplier_id   => $params->{supplier_id},
    );

    if ($match->{supplier} && $match->{supplier}{id}) {
        $self->write_json($c, 200, {
            success     => JSON::true,
            supplier_id => 0 + $match->{supplier}{id},
            name        => $match->{supplier}{name},
            sitename    => $sitename,
            status      => $match->{status},
        });
        return;
    }

    $self->write_json($c, 200, {
        success    => JSON::false,
        sitename   => $sitename,
        candidates => $match->{candidates} || [],
        error      => 'No supplier matched',
    });
}

sub write_json {
    my ($self, $c, $status, $payload) = @_;
    $c->response->status($status || 200);
    $c->response->content_type('application/json; charset=utf-8');
    $c->response->body(encode_json($payload));
}

sub perform_create {
    my ($self, $c, $params) = @_;
    unless ($self->_can_write_invoice($c)) {
        $self->write_json($c, 403, { success => JSON::false, error => 'Login with admin or accounting role required' });
        return;
    }
    my $result = $self->create_from_params($c, $params);
    my $http = 200;
    $http = 400 if !$result->{success} && $result->{error}
        && !$result->{need_supplier} && !$result->{need_pick} && !$result->{need_clarify}
        && !$result->{need_kind};
    $http = 500 if ($result->{error} || '') =~ /failed|not available/i
        && !$result->{need_supplier};
    $self->write_json($c, $http, $result);
}

__PACKAGE__->meta->make_immutable;
1;
