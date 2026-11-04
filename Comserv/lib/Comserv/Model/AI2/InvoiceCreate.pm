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

# "Item: salsa" / "Invoice number: 1" on one line or several. Stop at the next label.
sub _label_value {
    my ($text, $label) = @_;
    return '' unless defined $text && defined $label && $label =~ /\S/;
    my $stop = qr/\s+(?:Invoice\s+number|Invoice\s+date|Due\s+date|Currency|Item|Description|Qty|Quantity|Unit\s+cost|Location)\s*:/i;
    if ($text =~ /\b\Q$label\E\s*:\s*(.+?)(?=$stop|$)/i) {
        my $v = $1;
        $v =~ s/^\s+|\s+$//g;
        return $v;
    }
    return '';
}

# First number only. "Qty: 1. Created date may 17 2024" is 1, not 1.172024.
sub _first_number {
    my ($s) = @_;
    return '' unless defined $s && $s =~ /(\d+(?:\.\d+)?)/;
    return $1;
}

# One prompt can list several "Item:" blocks. Location applies to every line.
sub _parse_invoice_lines {
    my ($text) = @_;
    return [] unless defined $text && $text =~ /\bItem\s*:/i;
    my $location = _label_value($text, 'Location');
    my @chunks = split(/\bItem\s*:\s*/i, $text);
    shift @chunks;
    my @lines;
    for my $chunk (@chunks) {
        next unless defined $chunk && $chunk =~ /\S/;
        my $name = $chunk;
        $name =~ s/\s+(?:Description|Qty|Quantity|Unit\s+cost|Location|Created\s+date)\b.*//is;
        $name =~ s/^\s+|\s+$//g;
        next unless length $name >= 1;
        my $desc = '';
        if ($chunk =~ /\bDescription\s*:\s*(.+?)(?=\s+(?:Qty|Quantity|Unit\s+cost|Location|Item|Created\s+date)\b|$)/is) {
            $desc = $1;
            $desc =~ s/^\s+|\s+$//g;
        }
        my $created = '';
        if ($chunk =~ /\bCreated\s+date\s*:?\s*(.+?)(?=\s+(?:Unit\s+cost|Item|Location|Qty|Quantity|Description)\b|$)/is) {
            $created = $1;
            $created =~ s/^\s+|\s+$//g;
            $created =~ s/\.\s*$//;
        }
        if (length $created) {
            $desc = length($desc) ? "$desc. Created date $created" : "Created date $created";
        }
        my $qty = '1';
        if ($chunk =~ /\b(?:Qty|Quantity)\s*:\s*(\d+(?:\.\d+)?)/i) {
            $qty = $1;
        }
        my $cost = '0';
        if ($chunk =~ /\bUnit\s+cost\s*:\s*\$?\s*(\d+(?:\.\d+)?)/i) {
            $cost = $1;
        }
        push @lines, {
            name        => $name,
            description => length($desc) ? $desc : $name,
            quantity    => $qty,
            unit_cost   => $cost,
            location    => $location,
        };
    }
    return \@lines;
}

# "add these items to the last T invoice" is not a new invoice.
# A plain "add an invoice from T" still creates one.
sub _detect_append {
    my ($p) = @_;
    return unless $p =~ /\b(?:add|append|attach)\b.+\b(?:to|onto)\b.+\b(?:invoice|bill)\b/is;
    return unless $p =~ /\blast\b/i
        || $p =~ /\binvoice\s*#\s*\d+/i
        || $p =~ /\bto\s+invoice\s+\d+\b/i;
    my $party = '';
    if ($p =~ /\blast\s+([A-Za-z0-9][A-Za-z0-9 .,&'-]{0,40}?)\s+invoice\b/i) {
        $party = $1;
    }
    elsif ($p =~ /\blast\s+invoice\s+(?:from|for)\s+([A-Za-z][A-Za-z0-9 .,&'-]{0,40}?)(?=\s|$)/i) {
        $party = $1;
    }
    elsif ($p =~ /\bfrom\s+([A-Za-z][A-Za-z0-9 .,&'-]{0,40}?)(?=\s+(?:for|invoice|bill|item)|$)/i) {
        $party = $1;
    }
    $party =~ s/^\s+|\s+$//g;
    $party =~ s/\s+for$//i;
    my $target_id = '';
    if ($p =~ /\binvoice\s*#\s*(\d+)/i) {
        $target_id = $1;
    }
    elsif ($p =~ /\bto\s+invoice\s+(\d+)\b/i) {
        $target_id = $1;
    }
    my $lines = _parse_invoice_lines($p);
    return {
        append            => 1,
        kind              => 'supplier',
        party             => $party,
        supplier_name     => $party,
        target_invoice_id => $target_id,
        lines             => $lines,
        line_item         => @$lines ? $lines->[0]{name} : '',
        line_qty          => @$lines ? $lines->[0]{quantity} : '',
        line_unit_cost    => @$lines ? $lines->[0]{unit_cost} : '',
        line_location     => @$lines ? ($lines->[0]{location} || '') : '',
        notes             => "Added from Chat-with-AI:\n$p",
    };
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

    if (my $append = _detect_append($p)) {
        return $append;
    }

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
    # {0,40} so a one-character number ("Invoice number: 1") is kept.
    # The old {1,40} required a second character and silently dropped "1".
    if ($p =~ /\binvoice\s*(?:number|no\.?|#)\s*[:#]?\s*([A-Za-z0-9][\w\-\/]{0,40})/i) {
        $invoice_number = $1;
    }
    elsif ($p =~ /\b(?:inv|invoice)\s*#\s*([A-Za-z0-9][\w\-\/]{0,40})/i) {
        $invoice_number = $1;
    }
    $invoice_number = _label_value($p, 'Invoice number') if !length $invoice_number;

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
        # Prefer "from Caroline" over the earlier word "supplier".
        # "supplier invoice from Caroline for $18" otherwise captures
        # "invoice from Caroline".
        if ($p =~ /\bfrom\s+([A-Za-z][A-Za-z0-9 .,&'-]{0,60}?)(?=\s+(?:for|invoice|bill|dated|on\s+\d|\$)|$)/i) {
            $party = $1;
        }
        elsif ($p =~ /\b(?:supplier|vendor)\s+([A-Za-z][A-Za-z0-9 .,&'-]{0,60}?)(?=\s+(?:for|invoice|bill|dated|on\s+\d|\$)|$)/i) {
            $party = $1;
        }
    }
    else {
        if ($p =~ /\b(?:for|customer|client|to)\s+([A-Za-z][A-Za-z0-9 .,&'\-]{1,60}?)(?=\s+(?:for|invoice|dated|on\s+\d|\$)|$)/i) {
            $party = $1;
        }
    }
    $party =~ s/^\s+|\s+$//g;
    $party =~ s/\s+for$//i;
    $party =~ s/\s+(invoice|bill|receipt)$//i;

    my $line_item = _label_value($p, 'Item');
    my $line_desc = _label_value($p, 'Description');
    my $line_qty  = _label_value($p, 'Qty') || _label_value($p, 'Quantity');
    my $line_cost = _label_value($p, 'Unit cost');
    my $line_loc  = _label_value($p, 'Location');
    $line_qty  = _first_number($line_qty) if defined $line_qty && length $line_qty;
    $line_cost = _first_number($line_cost) if defined $line_cost && length $line_cost;
    my $lines = _parse_invoice_lines($p);
    if (@$lines) {
        $line_item = $lines->[0]{name};
        $line_desc = $lines->[0]{description};
        $line_qty  = $lines->[0]{quantity};
        $line_cost = $lines->[0]{unit_cost};
        $line_loc  = $lines->[0]{location} if length($lines->[0]{location} || '');
    }
    # Unit cost 0.00 is a stated total, not a missing one. Labels are parsed
    # above, so this cannot run before $line_cost exists.
    if (!defined $amount && defined $line_cost && $line_cost =~ /^\d/) {
        my $q = (defined $line_qty && $line_qty =~ /^\d/ && $line_qty > 0) ? $line_qty : 1;
        $amount = sprintf('%.2f', $q * $line_cost);
    }
    if (!defined $amount && $p =~ /\b(?:free|no cost|donated|donation|food bank)\b/i) {
        $amount = '0.00';
    }

    my $description = length($line_desc) ? $line_desc : $p;
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
        line_item       => $line_item,
        line_qty        => $line_qty,
        line_unit_cost  => $line_cost,
        line_location   => $line_loc,
        lines           => $lines,
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
7. Amount may be 0 or 0.00. Free, donated, and food-bank goods are a real total of 0.00. Do not refuse a zero total and do not invent a positive amount. Ask only when no amount was given at all.
8. Adding items to an existing draft is not a new invoice. The user says "add these items to the last T invoice" (or "to invoice #125") and lists Item / Description / Qty / Unit cost lines. Append those lines to that draft. Do not post. Do not change stock.

$list
END
}

sub create_from_params {
    my ($self, $c, $params) = @_;
    $params ||= {};
    if ($params->{append}) {
        return $self->_append_to_existing($c, $params);
    }
    my $sitename = $self->sitename($c);
    my $user     = $c->session->{username} || 'ai';
    my $kind     = ($params->{kind} || 'supplier') eq 'customer' ? 'customer' : 'supplier';
    my $today    = $self->_today;
    my $date     = $params->{invoice_date} || '';
    $date = $today unless $date =~ /^\d{4}-\d{2}-\d{2}$/;
    my $amount   = $params->{amount};
    $amount =~ s/^\s+|\s+$//g if defined $amount;
    $amount = undef unless defined $amount && $amount =~ /^\d+(\.\d{1,2})?$/;
    # A line can state the total when the header amount was omitted.
    # Unit cost 0.00 is a real total (food bank, donated goods), not a blank.
    if (!defined $amount && defined $params->{line_unit_cost}
        && $params->{line_unit_cost} =~ /^\d+(\.\d{1,2})?$/) {
        my $qty = $params->{line_qty};
        $qty = 1 unless defined $qty && $qty =~ /^\d+(?:\.\d+)?$/ && $qty > 0;
        $amount = sprintf('%.2f', $qty * $params->{line_unit_cost});
    }
    my $tax      = $params->{tax_amount} || 0;
    $tax = 0 unless $tax =~ /^\d+(\.\d{1,2})?$/;

    unless (defined $amount) {
        return {
            success      => JSON::false,
            need_clarify => JSON::true,
            field        => 'amount',
            draft        => $params,
            sitename     => $sitename,
            message      => 'I can enter the invoice as a draft, but I need the total amount. Use 0.00 when the goods were free or donated.',
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
        my $cands = $match->{candidates} || [];
        my @lines = map {
            '- ' . ($_->{name} || 'unnamed') . ' (#' . ($_->{id} // '?') . ')'
        } @$cands;
        my $head = @$cands == 1
            ? "One $sitename supplier could fit. Which one?"
            : "Several $sitename suppliers could fit. Which one?";
        return {
            success    => JSON::false,
            need_pick  => JSON::true,
            sitename   => $sitename,
            draft      => $params,
            candidates => $cands,
            message    => @lines ? "$head\n" . join("\n", @lines) : $head,
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

    my $item_note = '';
    my $inv_no = $params->{invoice_number} || '';
    if (length $inv_no) {
        my $already = eval {
            $schema->resultset('Accounting::InventorySupplierInvoice')->search({
                sitename       => $sitename,
                supplier_id    => $match->{supplier}{id},
                invoice_number => $inv_no,
            })->first;
        };
        if ($@) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
                'create_from_params', "duplicate invoice lookup failed: $@");
        }
        elsif ($already) {
            my $eid = $already->id;
            return {
                success     => JSON::true,
                invoice_id  => 0 + $eid,
                invoice_url => "/Inventory/invoice/view/$eid",
                message     => "Invoice number $inv_no already exists for this supplier as #$eid. Not creating another.",
                already_exists => JSON::true,
            };
        }
    }
    my $supplier_id = $match->{supplier}{id};
    my $parsed = $params->{lines};
    $parsed = [] unless ref $parsed eq 'ARRAY';
    if (!@$parsed) {
        $parsed = _parse_invoice_lines($params->{notes} || $params->{description} || '');
        $params->{lines} = $parsed if @$parsed;
    }
    my @ready;
    my @missing;
    if (@$parsed) {
        for my $ln (@$parsed) {
            my $one = {
                %$params,
                item_id        => '',
                item_name      => $ln->{name},
                line_item      => $ln->{name},
                description    => $ln->{description},
                line_qty       => $ln->{quantity},
                line_unit_cost => $ln->{unit_cost},
                line_location  => $ln->{location},
            };
            my $resolved = $self->_resolve_line_item(
                $c, $schema, $one, $sitename, $user, $supplier_id);
            if ($resolved->{need_item} || $resolved->{need_pick_item}) {
                push @missing, $resolved;
                next;
            }
            if ($resolved->{error}) {
                return { success => JSON::false, error => $resolved->{error}, draft => $params };
            }
            my $item = $resolved->{item};
            push @ready, {
                description => $ln->{description},
                quantity    => $ln->{quantity},
                unit_cost   => $ln->{unit_cost},
                item_id     => $item && $item->{id} ? $item->{id} : undef,
                item_name   => $item && $item->{name} ? $item->{name} : $ln->{name},
                created     => $resolved->{created} ? 1 : 0,
                location    => $ln->{location},
            };
        }
        if (@missing) {
            my $first = $missing[0];
            my $names = join(', ', map { $_->{item_name} || 'unnamed' } @missing);
            my $cands = $first->{candidates} || [];
            my $list = join("\n", map {
                my $who = $_->{supplier_name} ? " — $_->{supplier_name}" : '';
                '- ' . ($_->{name} || 'unnamed') . ' (#' . ($_->{id} // '?') . ")$who"
            } @$cands);
            my $msg = @missing > 1
                ? "These items are not in inventory yet: $names. Add them for this supplier?"
                : ($first->{message} || 'Which inventory item?');
            $msg .= "\n$list" if $list;
            return {
                success        => JSON::false,
                need_item      => $first->{need_item} ? JSON::true : JSON::false,
                need_pick_item => $first->{need_pick_item} ? JSON::true : JSON::false,
                supplier_mismatch => $first->{supplier_mismatch} ? JSON::true : JSON::false,
                sitename       => $sitename,
                draft          => $params,
                item_name      => $first->{item_name} || '',
                candidates     => $cands,
                message        => $msg,
            };
        }
    }
    else {
        my $line_item = $self->_resolve_line_item(
            $c, $schema, $params, $sitename, $user, $supplier_id);
        if ($line_item->{need_item} || $line_item->{need_pick_item}) {
            my $cands = $line_item->{candidates} || [];
            my $list = join("\n", map {
                my $who = $_->{supplier_name} ? " — $_->{supplier_name}" : '';
                '- ' . ($_->{name} || 'unnamed') . ' (#' . ($_->{id} // '?') . ")$who"
            } @$cands);
            my $msg = $line_item->{message} || 'Which inventory item?';
            $msg .= "\n$list" if $list;
            return {
                success        => JSON::false,
                need_item      => $line_item->{need_item} ? JSON::true : JSON::false,
                need_pick_item => $line_item->{need_pick_item} ? JSON::true : JSON::false,
                supplier_mismatch => $line_item->{supplier_mismatch} ? JSON::true : JSON::false,
                sitename       => $sitename,
                draft          => $params,
                item_name      => $line_item->{item_name} || '',
                candidates     => $cands,
                message        => $msg,
            };
        }
        if ($line_item->{error}) {
            return { success => JSON::false, error => $line_item->{error}, draft => $params };
        }
        my $item = $line_item->{item};
        push @ready, {
            description => $params->{description} || $params->{notes} || '',
            quantity    => $params->{line_qty},
            unit_cost   => $params->{line_unit_cost},
            item_id     => $item && $item->{id} ? $item->{id} : undef,
            item_name   => $item && $item->{name} ? $item->{name} : '',
            created     => $line_item->{created} ? 1 : 0,
            location    => $params->{line_location},
        };
    }
    my @created_names = map { $_->{item_name} } grep { $_->{created} } @ready;
    if (@created_names) {
        $item_note = ' Added inventory item'
            . (@created_names > 1 ? 's ' : ' ')
            . join(', ', @created_names)
            . ' for this supplier. Catalog price and stock stay unchanged until you Post.';
    }
    elsif (my @linked = grep { $_->{item_id} } @ready) {
        $item_note = ' Linked inventory item'
            . (@linked > 1 ? 's ' : ' ')
            . join(', ', map { $_->{item_name} . ' (#' . $_->{item_id} . ')' } @linked)
            . '. Catalog price and stock stay unchanged until you Post.';
    }
    my $location_id = $self->_match_location($c, $schema, $sitename, $params->{line_location});
    for my $ln (@ready) {
        $ln->{location_id} = $self->_match_location($c, $schema, $sitename, $ln->{location})
            || $location_id;
    }

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
        quantity       => $ready[0]{quantity},
        unit_cost      => $ready[0]{unit_cost},
        item_id        => $ready[0]{item_id},
        location_id    => $ready[0]{location_id},
        lines          => \@ready,
    });

    # Tell the user what we filled in so they can sanity-check it.
    if ($res->{success} && ref $enriched eq 'HASH' && %{ $enriched->{filled} || {} }) {
        my @kv = map { "$_=" . $enriched->{filled}{$_} }
                 sort keys %{ $enriched->{filled} };
        $res->{supplier_enriched} = [ sort keys %{ $enriched->{filled} } ];
        $res->{message} .= " I also filled in missing supplier contact info ("
                        .  join(', ', @kv) . ") - please verify it.";
    }
    $res->{message} .= $item_note if $res->{success} && $item_note;
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
        "Auto-created supplier #$supplier->id '$name' on $sitename" . ($enriched ? ' (web-enriched)' : ''));
    return { id => 0 + $supplier->id, name => $supplier->name // '' };
}

sub _web_lookup_supplier {
    my ($self, $c, $name) = @_;
    my $q = "supplier contact info $name email phone address website";
    my $ua = LWP::UserAgent->new(timeout => 10);
    $ua->agent('Comserv/2.0');

    my %result;
    eval {
        my $url = 'https://api.duckduckgo.com/?q='
                . uri_escape($q)
                . '&format=json&no_html=1&skip_disambig=1';
        my $req  = HTTP::Request->new(GET => $url);
        my $resp = $ua->request($req);
        if ($resp->is_success) {
            my $data = JSON::decode_json($resp->decoded_content);
            # Grab the best abstract as a starting point
            if ($data->{AbstractText} && $data->{AbstractURL}) {
                my $abstract = $data->{AbstractText};
                # Try to extract email from abstract/related topics
                if ($abstract =~ /[\w.-]+@[\w.-]+\.\w+/) {
                    $result{email} = $1;
                }
                # Try to extract phone-like patterns
                if ($abstract =~ /(\+?[\d\s\-\(\)]{7,20})/) {
                    $result{phone} = $1;
                }
            }
            # Search related topics for more specific info
            for my $t (@{ $data->{RelatedTopics} || [] }) {
                next unless ref($t) eq 'HASH' && $t->{Text} && $t->{FirstURL};
                last if keys %result >= 4;  # stop when we have enough
                my $text = $t->{Text};
                if ($text =~ /[\w.-]+@[\w.-]+\.\w+/) {
                    $result{email} = $1;
                }
                elsif ($text =~ /(\+?[\d\s\-\(\)]{7,20})/) {
                    $result{phone} = $1;
                }
                elsif ($t->{Text} =~ /address/i && $t->{Text} =~ /[\w\s,]+\s+\w+/) {
                    # Could be an address — too noisy, skip
                }
            }
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'web_lookup_supplier', "DDG lookup failed for '$name': $@");
        return undef;
    }
    return \%result if keys %result;
    return undef;
}

sub _resolve_line_item {
    my ($self, $c, $schema, $params, $sitename, $user, $supplier_id) = @_;
    my $name = $params->{item_name} || $params->{line_item} || '';
    $name =~ s/^\s+|\s+$//g;
    my $pid = $params->{item_id};
    if (defined $pid && $pid =~ /^\d+$/ && $pid > 0) {
        my $row = eval { $schema->resultset('Accounting::InventoryItem')->find($pid) };
        if ($row && ($row->sitename || '') eq $sitename) {
            return { item => { id => 0 + $row->id, name => $row->name // '' } };
        }
    }
    return {} unless length $name;
    return {} if $params->{skip_item};

    if ($params->{create_item}) {
        my $created = $self->_create_chat_item($c, $schema, {
            sitename    => $sitename,
            user        => $user,
            name        => $name,
            description => $params->{description} || '',
            unit_cost   => $params->{line_unit_cost},
            supplier_id => $supplier_id,
        });
        return { error => 'Could not add the inventory item' } unless $created && $created->{id};
        return { item => $created, created => 1 };
    }

    my $ranked = $self->rank_parties($name, $self->list_items($c, $sitename));
    if (!@$ranked) {
        return {
            need_item => 1,
            item_name => $name,
            message   => "No inventory item named \"$name\" on $sitename. Add it?",
        };
    }
    my $top = $ranked->[0];
    my $second = $ranked->[1];
    if ($top->{score} >= 70 && (!$second || ($top->{score} - $second->{score}) >= 12)) {
        return $self->_same_product_or_ask($c, $schema, $top, $name, $supplier_id);
    }
    if (@$ranked > 1 && $top->{score} >= 18) {
        my $last = $#$ranked > 7 ? 7 : $#$ranked;
        my @cands = map { $self->_annotate_item_supplier($c, $schema, $_) } @{$ranked}[0 .. $last];
        return {
            need_pick_item => 1,
            candidates     => \@cands,
            item_name      => $name,
            message        => "Several inventory items could be \"$name\". Which one? A different supplier means it may be a different product.",
        };
    }
    if (@$ranked == 1) {
        return $self->_same_product_or_ask($c, $schema, $top, $name, $supplier_id);
    }
    return {
        need_item => 1,
        item_name => $name,
        message   => "No inventory item named \"$name\" on $sitename. Add it?",
    };
}

sub _item_supplier_links {
    my ($self, $c, $schema, $item_id) = @_;
    my @out;
    eval {
        my $rs = $schema->resultset('Accounting::InventoryItemSupplier')->search({
            item_id => $item_id,
        });
        while (my $link = $rs->next) {
            my $sup = eval { $link->supplier };
            push @out, {
                supplier_id   => 0 + $link->supplier_id,
                supplier_name => ($sup && $sup->name) ? $sup->name : '',
            };
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            '_item_supplier_links', "lookup failed for item $item_id: $@");
    }
    return \@out;
}

sub _annotate_item_supplier {
    my ($self, $c, $schema, $item) = @_;
    my $links = $self->_item_supplier_links($c, $schema, $item->{id});
    my $who = join(', ', grep { length } map { $_->{supplier_name} } @$links);
    return {
        id            => $item->{id},
        name          => $item->{name},
        supplier_name => $who || 'no supplier on file',
    };
}

# A name match is not enough when the item is sold by a different supplier.
sub _same_product_or_ask {
    my ($self, $c, $schema, $item, $query, $supplier_id) = @_;
    my $links = $self->_item_supplier_links($c, $schema, $item->{id});
    my $same = 0;
    my @other;
    for my $l (@$links) {
        if ($supplier_id && $l->{supplier_id} == $supplier_id) {
            $same = 1;
        }
        elsif (length($l->{supplier_name} || '')) {
            push @other, $l->{supplier_name};
        }
    }
    if ($same) {
        return { item => { id => $item->{id}, name => $item->{name} } };
    }
    my $cand = $self->_annotate_item_supplier($c, $schema, $item);
    my $msg = @other
        ? "\"$item->{name}\" is already in inventory for " . join(', ', @other)
          . ". That is a different supplier. Same product, or a new item?"
        : "\"$item->{name}\" matches an inventory item that is not linked to this supplier. Same product, or a new item?";
    return {
        need_pick_item     => 1,
        supplier_mismatch  => 1,
        item_name          => $query,
        candidates         => [$cand],
        message            => $msg,
    };
}

sub list_items {
    my ($self, $c, $sitename) = @_;
    $sitename ||= $self->sitename($c);
    my $schema = $self->_schema($c) or return [];
    my @out;
    eval {
        my $rs = $schema->resultset('Accounting::InventoryItem')->search(
            { sitename => $sitename, status => 'active' },
            { order_by => 'name', rows => 200 },
        );
        while (my $s = $rs->next) {
            push @out, { id => 0 + $s->id, name => $s->name // '', sku => $s->sku // '' };
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'list_items', "Failed: $@");
    }
    return \@out;
}

sub _create_chat_item {
    my ($self, $c, $schema, $args) = @_;
    my $name = $args->{name} || '';
    $name =~ s/^\s+|\s+$//g;
    return undef unless length $name >= 2;
    my $sku = lc $name;
    $sku =~ s/[^a-z0-9]+/-/g;
    $sku =~ s/^-+|-+$//g;
    my $sid = $args->{supplier_id} || 0;
    $sku = 'chat-s' . $sid . '-' . ($sku || 'item');
    $sku = substr($sku, 0, 100);
    my $existing = eval {
        $schema->resultset('Accounting::InventoryItem')->find({
            sitename => $args->{sitename}, sku => $sku,
        });
    };
    if ($existing) {
        return { id => 0 + $existing->id, name => $existing->name // $name };
    }
    my $cost = $args->{unit_cost};
    $cost = undef unless defined $cost && $cost =~ /^\d+(?:\.\d+)?$/;
    my $now = DateTime->now->strftime('%Y-%m-%d %H:%M:%S');
    my $row = eval {
        $schema->resultset('Accounting::InventoryItem')->create({
            sitename            => $args->{sitename},
            sku                 => $sku,
            name                => $name,
            description         => $args->{description} || undef,
            item_origin         => 'purchased',
            is_assemblable      => 0,
            is_consumable       => 0,
            is_reusable         => 1,
            unit_of_measure     => 'each',
            unit_cost           => $cost,
            status              => 'active',
            notes               => 'Added from Chat-with-AI invoice entry.',
            show_in_shop        => 0,
            hide_stock_count    => 0,
            accepts_points      => 0,
            list_in_marketplace => 0,
            created_by          => $args->{user} || 'ai',
            created_at          => $now,
            updated_at          => $now,
        });
    };
    if ($@ || !$row) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            '_create_chat_item', "create failed for '$name': $@");
        return undef;
    }
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
        '_create_chat_item', "created item id=" . $row->id . " sku=$sku sitename=$args->{sitename}");
    if ($args->{supplier_id}) {
        my $link_ok = eval {
            $schema->resultset('Accounting::InventoryItemSupplier')->create({
                item_id     => $row->id,
                supplier_id => $args->{supplier_id},
                unit_cost   => $cost,
            });
            1;
        };
        if (!$link_ok) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
                '_create_chat_item', "supplier link failed for item " . $row->id . ": $@");
        }
    }
    return { id => 0 + $row->id, name => $row->name // $name };
}

sub _match_location {
    my ($self, $c, $schema, $sitename, $name) = @_;
    return undef unless $schema && defined $name && $name =~ /\S/;
    my $want = _norm($name);
    return undef unless length $want;
    my $id;
    eval {
        my $rs = $schema->resultset('Accounting::InventoryLocation')->search({
            sitename => $sitename,
        });
        while (my $loc = $rs->next) {
            if (_norm($loc->name) eq $want) {
                $id = 0 + $loc->id;
                last;
            }
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            '_match_location', "lookup failed for '$name': $@");
    }
    return $id;
}

sub _insert_supplier {
    my ($self, $c, $schema, $args) = @_;
    my $now = DateTime->now->strftime('%Y-%m-%d %H:%M:%S');
    my $line_amt = sprintf('%.2f', $args->{amount} - ($args->{tax_amount} || 0));
    $line_amt = $args->{amount} if $line_amt <= 0;
    my $qty = $args->{quantity};
    $qty = 1 unless defined $qty && $qty =~ /^\d+(?:\.\d+)?$/ && $qty > 0;
    my $unit = $args->{unit_cost};
    # 0 is a real unit cost (donated / food-bank goods). Only a missing cost
    # falls back to the invoice total.
    $unit = $line_amt unless defined $unit && $unit =~ /^\d+(?:\.\d+)?$/;
    my $line_total = sprintf('%.2f', $qty * $unit);
    my $invoice;
    eval {
        $schema->txn_do(sub {
            $invoice = $schema->resultset('Accounting::InventorySupplierInvoice')->create({
                sitename        => $args->{sitename},
                supplier_id     => $args->{supplier}{id},
                invoice_number  => (defined $args->{invoice_number} && length $args->{invoice_number})
                                    ? $args->{invoice_number} : undef,
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
            my @to_write = (ref $args->{lines} eq 'ARRAY' && @{$args->{lines}})
                ? @{$args->{lines}}
                : ({
                    description => $args->{description},
                    quantity    => $qty,
                    unit_cost   => $unit,
                    item_id     => $args->{item_id},
                    location_id => $args->{location_id},
                });
            my $sum = 0;
            for my $ln (@to_write) {
                my $q = $ln->{quantity};
                $q = 1 unless defined $q && $q =~ /^\d+(?:\.\d+)?$/ && $q > 0;
                my $u = $ln->{unit_cost};
                $u = 0 unless defined $u && $u =~ /^\d+(?:\.\d+)?$/;
                my $lt = sprintf('%.2f', $q * $u);
                $sum += $lt;
                my %line = (
                    description => $self->_clamp_description($ln->{description}),
                    quantity    => $q,
                    unit_cost   => sprintf('%.4f', $u),
                    line_total  => $lt,
                );
                $line{item_id} = $ln->{item_id} if $ln->{item_id};
                $line{location_id} = $ln->{location_id} if $ln->{location_id};
                $invoice->create_related('lines', \%line);
            }
            my $grand = (@to_write > 1 ? $sum : $line_total) + ($args->{tax_amount} || 0);
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
        "Draft AP invoice #$id sitename=$args->{sitename} supplier=$args->{supplier}{id} invoice_number="
        . (defined $args->{invoice_number} && length $args->{invoice_number} ? $args->{invoice_number} : '(none)')
        . " by=$args->{user}");
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

# Add item lines to an existing draft. Does not create a new invoice,
# does not post, and does not change stock or the catalog price.
sub _append_to_existing {
    my ($self, $c, $params) = @_;
    $params ||= {};
    my $sitename = $self->sitename($c);
    my $user     = $c->session->{username} || 'ai';
    my $schema = $self->_schema($c)
        or return { success => JSON::false, error => 'Database not available' };

    my $found = $self->_find_append_invoice($c, $schema, $sitename, $params);
    return $found if $found->{need_pick} || $found->{error} || !$found->{invoice};
    my $invoice = $found->{invoice};
    $params->{target_invoice_id} = 0 + $invoice->id;
    $params->{supplier_id} = 0 + ($invoice->supplier_id || 0);
    $params->{append} = 1;

    my $parsed = $params->{lines};
    $parsed = [] unless ref $parsed eq 'ARRAY';
    if (!@$parsed) {
        $parsed = _parse_invoice_lines($params->{notes} || '');
        $params->{lines} = $parsed if @$parsed;
    }
    unless (@$parsed) {
        my $who = $found->{supplier_name} || 'that supplier';
        return {
            success  => JSON::false,
            sitename => $sitename,
            draft    => $params,
            message  => "I can add items to draft #$params->{target_invoice_id} for $who, but I need each item listed. "
                      . "Example: Item: Peas Description: 1 kg bag Qty: 2 Unit cost: 0.00",
        };
    }

    my $supplier_id = $invoice->supplier_id;
    my @ready;
    my @missing;
    for my $ln (@$parsed) {
        my $one = {
            %$params,
            item_id        => '',
            item_name      => $ln->{name},
            line_item      => $ln->{name},
            description    => $ln->{description},
            line_qty       => $ln->{quantity},
            line_unit_cost => $ln->{unit_cost},
            line_location  => $ln->{location},
        };
        my $resolved = $self->_resolve_line_item(
            $c, $schema, $one, $sitename, $user, $supplier_id);
        if ($resolved->{need_item} || $resolved->{need_pick_item}) {
            push @missing, $resolved;
            next;
        }
        if ($resolved->{error}) {
            return { success => JSON::false, error => $resolved->{error}, draft => $params };
        }
        my $item = $resolved->{item};
        push @ready, {
            description => $ln->{description},
            quantity    => $ln->{quantity},
            unit_cost   => $ln->{unit_cost},
            item_id     => $item && $item->{id} ? $item->{id} : undef,
            item_name   => $item && $item->{name} ? $item->{name} : $ln->{name},
            created     => $resolved->{created} ? 1 : 0,
            location    => $ln->{location},
        };
    }
    if (@missing) {
        my $first = $missing[0];
        my $names = join(', ', map { $_->{item_name} || 'unnamed' } @missing);
        my $cands = $first->{candidates} || [];
        my $msg = @missing > 1
            ? "These items are not on this invoice yet: $names. Add them for this supplier?"
            : ($first->{message} || 'Which inventory item?');
        return {
            success           => JSON::false,
            need_item         => $first->{need_item} ? JSON::true : JSON::false,
            need_pick_item    => $first->{need_pick_item} ? JSON::true : JSON::false,
            supplier_mismatch => $first->{supplier_mismatch} ? JSON::true : JSON::false,
            sitename          => $sitename,
            draft             => $params,
            item_name         => $first->{item_name} || '',
            candidates        => $cands,
            message           => $msg,
            invoice_id        => 0 + $invoice->id,
            invoice_url       => '/Inventory/invoice/view/' . $invoice->id,
        };
    }

    my %already;
    eval {
        my $rs = $schema->resultset('Accounting::InventorySupplierInvoiceLine')->search({
            invoice_id => $invoice->id,
        });
        while (my $row = $rs->next) {
            $already{$row->item_id} = 1 if $row->item_id;
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            '_append_to_existing', "could not read existing lines on invoice " . $invoice->id . ": $@");
    }

    my @added;
    my @skipped;
    my $now = DateTime->now->strftime('%Y-%m-%d %H:%M:%S');
    my $ok = eval {
        $schema->txn_do(sub {
            for my $ln (@ready) {
                if ($ln->{item_id} && $already{$ln->{item_id}}) {
                    push @skipped, $ln->{item_name};
                    next;
                }
                my $q = $ln->{quantity};
                $q = 1 unless defined $q && $q =~ /^\d+(?:\.\d+)?$/ && $q > 0;
                my $u = $ln->{unit_cost};
                $u = 0 unless defined $u && $u =~ /^\d+(?:\.\d+)?$/;
                my $loc = $self->_match_location($c, $schema, $sitename, $ln->{location});
                my %line = (
                    description => $self->_clamp_description($ln->{description}),
                    quantity    => $q,
                    unit_cost   => sprintf('%.4f', $u),
                    line_total  => sprintf('%.2f', $q * $u),
                );
                $line{item_id} = $ln->{item_id} if $ln->{item_id};
                $line{location_id} = $loc if $loc;
                $invoice->create_related('lines', \%line);
                $already{$ln->{item_id}} = 1 if $ln->{item_id};
                push @added, $ln->{item_name};
            }
            my $sum = $schema->resultset('Accounting::InventorySupplierInvoiceLine')->search({
                invoice_id => $invoice->id,
            })->get_column('line_total')->sum || 0;
            my $tax = $invoice->tax_amount || 0;
            $invoice->update({
                total_amount => sprintf('%.2f', $sum + $tax),
                updated_at   => $now,
            });
        });
        1;
    };
    if (!$ok) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            '_append_to_existing', "append failed on invoice " . $invoice->id . ": $@");
        return { success => JSON::false, error => 'Could not add the items to the invoice' };
    }

    my $id = $invoice->id;
    my $who = $found->{supplier_name} || 'the supplier';
    my $msg;
    if (@added) {
        $msg = 'Added ' . join(', ', @added) . " to draft #$id for $who. "
             . 'Catalog price and stock stay unchanged until you Post.';
        $msg .= ' Already on this invoice, so not added again: ' . join(', ', @skipped) . '.'
            if @skipped;
    }
    else {
        $msg = @skipped
            ? "Those items are already on draft #$id for $who. Nothing new was added."
            : "No items were added to draft #$id.";
    }
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_append_to_existing',
        "Appended to draft #$id sitename=$sitename added=" . join(',', @added) . " by=$user");
    return {
        success     => JSON::true,
        appended    => JSON::true,
        invoice_id  => 0 + $id,
        invoice_url => "/Inventory/invoice/view/$id",
        sitename    => $sitename,
        message     => $msg,
    };
}

sub _find_append_invoice {
    my ($self, $c, $schema, $sitename, $params) = @_;
    my $target = $params->{target_invoice_id} || '';
    if ($target =~ /^\d+$/ && $target > 0) {
        my $row = eval {
            $schema->resultset('Accounting::InventorySupplierInvoice')->find($target);
        };
        if ($@) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
                '_find_append_invoice', "lookup #$target failed: $@");
            return { error => 'Could not look up that invoice' };
        }
        return { error => "Invoice #$target was not found." } unless $row;
        return { error => "Invoice #$target is on another site." }
            unless ($row->sitename || '') eq $sitename;
        my $status = $row->status || '';
        return { error => "Invoice #$target is $status. Chat only adds lines to a draft." }
            unless $status eq 'draft';
        my $sup = eval { $row->supplier };
        return {
            invoice       => $row,
            supplier_name => ($sup && $sup->name) ? $sup->name : '',
        };
    }

    my $party = $params->{party} || $params->{supplier_name} || '';
    $party =~ s/^\s+|\s+$//g;
    return { error => 'Say which supplier, for example: add these items to the last T invoice.' }
        unless length $party;
    my $match = $self->match_supplier($c,
        sitename      => $sitename,
        supplier_id   => $params->{supplier_id},
        supplier_name => $party,
        party         => $party,
    );
    if (($match->{status} || '') eq 'ambiguous') {
        return {
            success    => JSON::false,
            need_pick  => JSON::true,
            sitename   => $sitename,
            draft      => $params,
            candidates => $match->{candidates} || [],
            message    => "Several suppliers could be \"$party\". Which invoice should get the items?",
        };
    }
    my $supplier = $match->{supplier};
    unless ($supplier && $supplier->{id}) {
        return { error => "No supplier named \"$party\" on $sitename. I will not create a supplier just to add lines." };
    }
    my $row = eval {
        $schema->resultset('Accounting::InventorySupplierInvoice')->search({
            sitename    => $sitename,
            supplier_id => $supplier->{id},
            status      => 'draft',
        }, { order_by => { -desc => 'id' } })->first;
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            '_find_append_invoice', "draft search for $party failed: $@");
        return { error => 'Could not look up the last invoice' };
    }
    return { error => "No draft invoice for $supplier->{name} on $sitename." } unless $row;
    return { invoice => $row, supplier_name => $supplier->{name} };
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
