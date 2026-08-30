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
use Comserv::Util::Logging;

extends 'Catalyst::Model';

has 'logging' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Comserv::Util::Logging->instance },
);

sub sitename {
    my ($self, $c) = @_;
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

    my $amount;
    if ($p =~ /\$\s*(\d[\d,]*(?:\.\d{1,2})?)/) {
        ($amount = $1) =~ s/,//g;
    }
    elsif ($p =~ /\b(?:total|amount|for)\s+(\d[\d,]*(?:\.\d{1,2})?)\s*(?:cad|usd|dollars?)?\b/i) {
        ($amount = $1) =~ s/,//g;
    }

    my $tax;
    if ($p =~ /\b(?:tax|gst|hst|pst)\s*:?\s*\$?\s*(\d[\d,]*(?:\.\d{1,2})?)/i) {
        ($tax = $1) =~ s/,//g;
    }

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

    return {
        kind            => $kind,
        invoice_number  => $invoice_number,
        invoice_date    => $invoice_date,
        amount          => $amount,
        tax_amount      => $tax,
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
    my $ranked = $self->rank_parties($q, $self->list_suppliers($c, $sitename));
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
        $list = "Active suppliers on $sitename (use id or name — do NOT invent ids):\n";
        for my $s (@$suppliers[0 .. ($#$suppliers < 19 ? $#$suppliers : 19)]) {
            $list .= sprintf("  #%s %s\n", $s->{id}, $s->{name} || '(unnamed)');
        }
    }
    else {
        $list = "No active suppliers listed for $sitename yet. Ask which supplier, or send the user to /Inventory/supplier.\n";
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
5. If supplier is missing or ambiguous the server will ASK — do not invent a supplier_id.
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
        return {
            success       => JSON::false,
            need_supplier => JSON::true,
            sitename      => $sitename,
            draft         => $params,
            candidates    => $match->{candidates} || [],
            message       => "No supplier on $sitename matches. Name the supplier, or add one at /Inventory (then retry).",
        };
    }

    return $self->_insert_supplier($c, $schema, {
        sitename       => $sitename,
        user           => $user,
        today          => $today,
        invoice_date   => $date,
        amount         => $amount,
        tax_amount     => $tax,
        supplier       => $match->{supplier},
        invoice_number => $params->{invoice_number} || '',
        description    => $params->{description} || $params->{notes} || '',
        notes          => $params->{notes} || '',
    });
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
                status          => 'draft',
                notes           => $args->{notes},
                created_by      => $args->{user},
                created_at      => $now,
                updated_at      => $now,
                currency        => 'CAD',
            });
            $invoice->create_related('lines', {
                description => $args->{description} || 'Entered from chat',
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
        message        => "Draft supplier invoice #$id saved for $args->{supplier}{name} on $args->{sitename}. Accounting still needs to review and Post — chat does not post the GL.",
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
                description => $args->{description} || 'Entered from chat',
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
        message        => "Draft sales invoice #$id saved for $name on $args->{sitename}. Accounting still needs to review and Post — chat does not post the GL.",
    };
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
        && !$result->{need_supplier} && !$result->{need_pick} && !$result->{need_clarify};
    $http = 500 if ($result->{error} || '') =~ /failed|not available/i
        && !$result->{need_supplier};
    $self->write_json($c, $http, $result);
}

__PACKAGE__->meta->make_immutable;
1;
