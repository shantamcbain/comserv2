package Comserv::Util::Inventory::MailInvoiceStock;

use strict;
use warnings;

use JSON;
use File::Spec;
use Comserv::Util::Logging;
use Comserv::Util::AppTime;
use Comserv::Util::MailInvoiceClassifier;

=head1 NAME

Comserv::Util::Inventory::MailInvoiceStock - supplier-invoice mail to on-hand stock

=head1 DESCRIPTION

Turns classified supplier-invoice mail into sitename-scoped supplier invoices
and receives stock for lines that match existing items. Does not post GL.
Automatic apply does not create inventory items. Queue Accept does, and only
for 3d, CSC, and Shanta, after a person has corrected the lines.

Watch-list addresses are the mailboxes that receive the invoice (To / Cc /
Delivered-To), not the supplier's From address. A mailbox can be watched by
more than one SiteName. The invoice still belongs to one site: the site that
owns the supplier row matched by the From address. A shared address never
copies a CSC supplier invoice onto Shanta, or the reverse.

=cut

sub new {
    my ($class) = @_;
    return bless {
        logging => Comserv::Util::Logging->instance,
    }, $class;
}

sub apply {
    my ($self, $c, %args) = @_;
    unless ($c && $c->can('model')) {
        return { ok => 0, error => 'no app context' };
    }
    my $classifier = $args{classifier} || Comserv::Util::MailInvoiceClassifier->new;
    my $all = $classifier->load_monitor_config;
    my $sites = $all->{sites} || {};
    my $file = $args{file} || $self->_classified_file($c, $classifier);
    unless ($file && -f $file) {
        $self->{logging}->log_with_details($c, 'warn', __FILE__, __LINE__, 'apply',
            "classified file missing: " . ($file || ''));
        return { ok => 0, error => "classified file missing: $file. Run classification first." };
    }

    my $data = $self->_read_json($c, $file);
    return $data if !$data->{ok} && $data->{error} && !$data->{categories};
    my $cats = $data->{categories} || {};
    my @targets = $self->_target_sites($sites, $args{sitename});
    unless (@targets) {
        return { ok => 0, error => 'no sitename configured for invoice mail' };
    }

    my $schema = eval { $c->model('DBEncy') };
    if ($@ || !$schema) {
        $self->{logging}->log_with_details($c, 'error', __FILE__, __LINE__, 'apply',
            "schema: $@");
        return { ok => 0, error => "schema unavailable: $@" };
    }

    my (@created, @received, @skipped, @site_rows);
    my %seen_skip;
    my $invoice_msgs = 0;
    for my $sitename (@targets) {
        my $config = $classifier->config_for_site($all, $sitename);
        my $site_created = 0;
        my $site_received = 0;
        my $site_skipped = 0;
        for my $cat (sort keys %$cats) {
            next if $cat eq 'personal';
            for my $msg (@{ $cats->{$cat}{invoices} || [] }) {
                next unless $msg && $msg->{is_invoice};
                $invoice_msgs++ if $args{sitename}; # counted per requested site below
                my ($owner, $why) = $self->owner_site($schema, $sites, $msg, $cat);
                if (!$owner || lc($owner) ne lc($sitename)) {
                    my $key = ($msg->{id} || '') . '|' . ($why || 'skip') . '|' . ($owner || '');
                    unless ($seen_skip{$key}++) {
                        push @skipped, {
                            id      => $msg->{id} || '',
                            reason  => $owner ? 'other_site' : ($why || 'unknown_supplier'),
                            owner   => $owner,
                            subject => $msg->{subject} || '',
                        };
                    }
                    $site_skipped++;
                    next;
                }
                my $one = $self->_apply_one($c, $schema, $classifier, $sitename, $config, $msg);
                if ($one->{received}) {
                    push @received, $one;
                    $site_received++;
                } elsif ($one->{created}) {
                    push @created, $one;
                    $site_created++;
                } else {
                    push @skipped, $one;
                    $site_skipped++;
                }
            }
        }
        push @site_rows, {
            sitename => $sitename,
            created  => $site_created,
            received => $site_received,
            skipped  => $site_skipped,
        };
        $self->{logging}->log_with_details($c, 'info', __FILE__, __LINE__, 'apply',
            "sitename=$sitename received=$site_received created=$site_created skipped=$site_skipped");
    }

    my $flagged = 0;
    for my $cat (keys %$cats) {
        for my $msg (@{ $cats->{$cat}{invoices} || [] }) {
            $flagged++ if $msg && $msg->{is_invoice};
        }
    }
    return {
        ok             => 1,
        file           => $file,
        invoice_messages => $flagged,
        created        => \@created,
        received       => \@received,
        skipped        => \@skipped,
        sites          => \@site_rows,
        summary        => $self->summary_text({
            invoice_messages => $flagged,
            created          => \@created,
            received         => \@received,
            skipped          => \@skipped,
        }),
    };
}

sub summary_text {
    my ($self, $res) = @_;
    $res ||= {};
    my $flagged = $res->{invoice_messages} || 0;
    my $recv = ref($res->{received}) eq 'ARRAY' ? scalar @{ $res->{received} } : 0;
    my $made = ref($res->{created}) eq 'ARRAY' ? scalar @{ $res->{created} } : 0;
    my $skip = ref($res->{skipped}) eq 'ARRAY' ? scalar @{ $res->{skipped} } : 0;
    if (!$flagged) {
        return 'Classified mail has no supplier invoices, so stock was not changed. '
            . 'The last scan did not contain invoice mail. Run classification after supplier invoices arrive in a watched mailbox.';
    }
    return "Mail stock: $recv invoice(s) received into stock, $made left as draft, $skip skipped. "
        . "$flagged invoice message(s) in the classified file.";
}

sub matching_sites {
    my ($self, $sites, $msg) = @_;
    my @hit;
    for my $name (sort keys %{ $sites || {} }) {
        push @hit, $name if $self->site_receives($sites->{$name}, $msg);
    }
    return @hit;
}

# The mailbox is not the site. shanta@forager.com receives bank and purchase
# mail for more than one SiteName. The supplier row owns the invoice.
sub owner_site {
    my ($self, $schema, $sites, $msg, $cat) = @_;
    my @watched = $self->matching_sites($sites, $msg);
    return (undef, 'not_watched') unless @watched;
    my ($from) = $self->emails_in($msg->{from});
    my @by_supplier = $self->sites_owning_supplier($schema, $from);
    my %watch = map { lc($_) => 1 } @watched;
    my @hit = grep { $watch{ lc($_) } } @by_supplier;
    return ($hit[0], 'supplier') if @hit == 1;
    return (undef, 'ambiguous_supplier') if @hit > 1;
    # Supplier exists, but on a site that does not watch this copy of the mail.
    # Still do not file it under a site that only shares the bank address.
    return (undef, 'supplier_other_site') if @by_supplier;
    my @by_cat;
    for my $name (@watched) {
        push @by_cat, $name if $self->category_owns($sites->{$name}, $cat);
    }
    return ($by_cat[0], 'category') if @by_cat == 1;
    return (undef, 'ambiguous_category') if @by_cat > 1;
    return (undef, 'unknown_supplier');
}

sub queue_rows {
    my ($self, $c) = @_;
    my @rows;
    my $classifier = Comserv::Util::MailInvoiceClassifier->new;
    my $all = $classifier->load_monitor_config;
    my $sites = $all->{sites} || {};
    my $schema = eval { $c->model('DBEncy') };
    my $file = $self->_classified_file($c, $classifier);
    my $data = ($file && -f $file) ? $self->_read_json($c, $file) : {};
    my $cats = ref($data) eq 'HASH' ? ($data->{categories} || {}) : {};
    my $mail_invoices = 0;
    for my $cat (sort keys %$cats) {
        next if $cat eq 'other' || $cat eq 'personal';
        for my $msg (@{ $cats->{$cat}{invoices} || [] }) {
            next unless $msg && $msg->{is_invoice};
            $mail_invoices++;
            my ($owner, $why) = $schema
                ? $self->owner_site($schema, $sites, $msg, $cat)
                : (undef, 'no_schema');
            my ($from) = $self->emails_in($msg->{from});
            my $supplier = $self->_supplier_label($schema, $from);
            my @parsed = eval {
                $classifier->_parse_invoice_line_items(
                    $classifier->message_body($msg), $msg->{subject}, $msg->{from},
                );
            };
            @parsed = ({ name => $msg->{subject} || '(no lines parsed)' }) unless @parsed;
            my $mailbox = join(', ', $self->emails_in($msg->{to}, $msg->{cc}, $msg->{delivered_to}));
            for my $line (@parsed) {
                push @rows, {
                    source => 'mail',
                    date => $msg->{date} || '',
                    invoice => $msg->{subject} || '',
                    item => $line->{name} || $line->{sku} || '',
                    qty => $line->{quantity} // '',
                    cost => $line->{price} // '',
                    mailbox => $mailbox,
                    from => $from || '',
                    sitename => $owner || 'unassigned',
                    site_reason => $why || '',
                    supplier => $supplier || 'no supplier match',
                    item_site => '',
                };
                last if @rows >= 300;
            }
            last if @rows >= 300;
        }
        last if @rows >= 300;
    }
    if ($schema && @rows < 300) {
        my @inv = eval {
            $schema->resultset('Accounting::InventorySupplierInvoice')->search(
                { sitename => { -in => [qw(3d CSC Shanta)] } },
                { order_by => { -desc => 'id' } },
            )->all;
        };
        for my $inv (@inv) {
            my $sup = eval { $inv->supplier };
            my $sup_name = ($sup && $sup->name) ? $sup->name : 'no supplier match';
            my $sup_site = ($sup && $sup->sitename) ? $sup->sitename : '';
            $sup_name .= " (supplier site $sup_site)" if $sup_site && $sup_site ne ($inv->sitename || '');
            my @lines = eval { $inv->lines->all };
            @lines = () if $@ || !@lines;
            for my $line (@lines) {
                next unless ref $line;
                my $item = eval { $line->item };
                push @rows, {
                    source => 'filed',
                    date => ($inv->invoice_date || '') . '',
                    invoice => $inv->invoice_number || '',
                    item => $line->description || ($item && $item->name) || '',
                    qty => $line->quantity,
                    cost => $line->unit_cost,
                    mailbox => '',
                    from => ($sup && $sup->email) ? $sup->email : '',
                    sitename => $inv->sitename || 'unassigned',
                    site_reason => 'already filed',
                    supplier => $sup_name,
                    item_site => ($item && $item->sitename) ? $item->sitename : '',
                };
                last if @rows >= 300;
            }
            last if @rows >= 300;
        }
    }
    my $note = $mail_invoices
        ? "$mail_invoices invoice message(s) from the last classification, plus lines already filed for 3d, CSC, and Shanta."
        : 'The last classification had no invoice messages. The rows below are supplier-invoice lines already filed for 3d, CSC, and Shanta.';
    return { rows => \@rows, note => $note, mail_invoices => $mail_invoices };
}

sub queue_invoices {
    my ($self, $c) = @_;
    my $schema = eval { $c->model('DBEncy') };
    my (@invoices, @suppliers, @sites);
    if ($schema) {
        my @inv = eval {
            $schema->resultset('Accounting::InventorySupplierInvoice')->search(
                { sitename => { -in => [qw(3d CSC Shanta)] } },
                { order_by => { -desc => 'id' } },
            )->all;
        };
        @inv = () if $@;
        for my $inv (@inv) {
            next unless ref $inv;
            my $sup = eval { $inv->supplier };
            my @lines = eval { $inv->lines->all };
            @lines = () if $@;
            my @out;
            for my $line (@lines) {
                next unless ref $line;
                my $item = eval { $line->item };
                push @out, {
                    line_id    => $line->id,
                    item_id    => $line->item_id,
                    item       => $line->description || ($item && $item->name) || '',
                    sku        => ($item && $item->sku) || '',
                    qty        => $line->quantity,
                    cost       => $line->unit_cost,
                    item_site  => ($item && $item->sitename) || '',
                    barcode    => ($item && $item->barcode) || '',
                };
            }
            push @invoices, {
                id             => $inv->id,
                invoice        => $inv->invoice_number || '',
                date           => ($inv->invoice_date || '') . '',
                status         => $inv->status || '',
                sitename       => $inv->sitename || '',
                supplier_id    => $inv->supplier_id,
                supplier       => ($sup && $sup->name) ? $sup->name : 'no supplier match',
                supplier_site  => ($sup && $sup->sitename) || '',
                lines          => \@out,
            };
        }
        my @sup = eval {
            $schema->resultset('Accounting::InventorySupplier')->search(
                { status => 'active' },
                { order_by => [ 'name', 'sitename' ] },
            )->all;
        };
        @sup = () if $@;
        for my $s (@sup) {
            next unless ref $s;
            push @suppliers, {
                id       => $s->id,
                name     => $s->name || '',
                sitename => $s->sitename || '',
            };
        }
        my @site_rows = eval {
            $schema->resultset('Site')->search({}, { order_by => 'name' })->all;
        };
        @site_rows = () if $@;
        for my $s (@site_rows) {
            next unless ref $s && defined $s->name && $s->name ne '';
            push @sites, $s->name;
        }
    }
    return {
        invoices  => \@invoices,
        suppliers => \@suppliers,
        sites     => \@sites,
        note      => 'One block per invoice. SiteName on the invoice or on an item is the move and does not rewrite stock. Accept is the only action that creates a missing item and adds on-hand. It does not post the general ledger.',
    };
}

sub update_invoice_assignment {
    my ($self, $c, %args) = @_;
    my $schema = eval { $c->model('DBEncy') };
    return { ok => 0, error => 'no database' } unless $schema;
    my $id = $args{invoice_id};
    my $sitename = $args{sitename};
    my $supplier_id = $args{supplier_id};
    return { ok => 0, error => 'Choose a SiteName and a supplier.' }
        unless $id && defined $sitename && $sitename ne '' && $supplier_id;

    my $inv = eval { $schema->resultset('Accounting::InventorySupplierInvoice')->find($id) };
    return { ok => 0, error => 'Invoice not found.' } unless $inv && !$@;

    my $site_ok = eval { $schema->resultset('Site')->search({ name => $sitename })->count };
    return { ok => 0, error => 'Unknown SiteName.' } unless $site_ok && !$@;

    my $supplier = eval { $schema->resultset('Accounting::InventorySupplier')->find($supplier_id) };
    return { ok => 0, error => 'Supplier not found.' } unless $supplier && !$@;
    return { ok => 0, error => 'Supplier is not active.' }
        unless ($supplier->status || '') eq 'active';

    my $number = $inv->invoice_number;
    if (defined $number && $number ne '') {
        my $clash = eval {
            $schema->resultset('Accounting::InventorySupplierInvoice')->search({
                sitename       => $sitename,
                invoice_number => $number,
                id             => { '!=' => $inv->id },
            })->first;
        };
        if ($@) {
            $self->{logging}->log_with_details($c, 'error', __FILE__, __LINE__, 'update_invoice_assignment', "$@");
            return { ok => 0, error => 'Could not check for a duplicate invoice number.' };
        }
        if ($clash) {
            return { ok => 0, error => "Invoice $number is already on $sitename." };
        }
    }

    my $old_site = $inv->sitename || '';
    my $old_sup  = $inv->supplier_id || '';
    eval { $inv->update({ sitename => $sitename, supplier_id => $supplier->id }) };
    if ($@) {
        $self->{logging}->log_with_details($c, 'error', __FILE__, __LINE__, 'update_invoice_assignment', "$@");
        return { ok => 0, error => 'Could not save the invoice.' };
    }
    $self->{logging}->log_with_details($c, 'info', __FILE__, __LINE__, 'update_invoice_assignment',
        "invoice $id sitename $old_site -> $sitename supplier $old_sup -> " . $supplier->id);
    return { ok => 1 };
}

sub update_item_site {
    my ($self, $c, %args) = @_;
    my $schema = eval { $c->model('DBEncy') };
    return { ok => 0, error => 'no database' } unless $schema;
    my $id = $args{item_id};
    my $sitename = $args{sitename};
    return { ok => 0, error => 'Choose a SiteName.' }
        unless $id && defined $sitename && $sitename ne '';

    my $item = eval { $schema->resultset('Accounting::InventoryItem')->find($id) };
    return { ok => 0, error => 'Item not found.' } unless $item && !$@;

    my $site_ok = eval { $schema->resultset('Site')->search({ name => $sitename })->count };
    return { ok => 0, error => 'Unknown SiteName.' } unless $site_ok && !$@;

    my $sku = $item->sku;
    if (defined $sku && $sku ne '') {
        my $clash = eval {
            $schema->resultset('Accounting::InventoryItem')->search({
                sitename => $sitename,
                sku      => $sku,
                id       => { '!=' => $item->id },
            })->first;
        };
        if ($@) {
            $self->{logging}->log_with_details($c, 'error', __FILE__, __LINE__, 'update_item_site', "$@");
            return { ok => 0, error => 'Could not check for a duplicate SKU.' };
        }
        if ($clash) {
            return { ok => 0, error => "SKU $sku is already on $sitename." };
        }
    }

    my %set = ( sitename => $sitename );
    if (exists $args{barcode}) {
        my $barcode = $args{barcode};
        $barcode = '' unless defined $barcode;
        $barcode =~ s/^\s+|\s+$//g;
        $set{barcode} = (length $barcode ? $barcode : undef);
        $set{barcode_type} = $self->_barcode_type($barcode);
    }
    my $old_site = $item->sitename || '';
    eval { $item->update(\%set) };
    if ($@) {
        $self->{logging}->log_with_details($c, 'error', __FILE__, __LINE__, 'update_item_site', "$@");
        return { ok => 0, error => 'Could not save the item.' };
    }
    $self->{logging}->log_with_details($c, 'info', __FILE__, __LINE__, 'update_item_site',
        "item $id sitename $old_site -> $sitename");
    return { ok => 1 };
}

sub _barcode_type {
    my ($self, $barcode) = @_;
    return undef unless defined $barcode && $barcode =~ /^\d+$/;
    my $n = length $barcode;
    return 'upc' if $n == 8 || $n == 12;
    return 'ean' if $n == 13 || $n == 14;
    return 'other';
}

sub _supplier_label {
    my ($self, $schema, $from) = @_;
    return '' unless $schema && $from;
    my @rows = eval {
        $schema->resultset('Accounting::InventorySupplier')->search({ status => 'active' })->all;
    };
    return '' if $@;
    my @hit;
    for my $row (@rows) {
        my ($em) = $self->emails_in($row->email);
        next unless $em && $em eq lc($from);
        my $label = $row->name || $em;
        $label .= ' on ' . $row->sitename if $row->sitename;
        push @hit, $label;
    }
    return join('; ', @hit);
}

sub sites_owning_supplier {
    my ($self, $schema, $from_email) = @_;
    return () unless $from_email && $schema;
    my @rows = eval {
        $schema->resultset('Accounting::InventorySupplier')->search({
            status => 'active',
        })->all;
    };
    return () if $@;
    my %sites;
    for my $row (@rows) {
        my ($em) = $self->emails_in($row->email);
        next unless $em && $em eq lc($from_email);
        my $site = $row->sitename or next;
        $sites{$site} = 1;
    }
    return sort keys %sites;
}

sub category_owns {
    my ($self, $config, $cat) = @_;
    return 0 unless $cat && $config;
    my $filter = $config->{category_filter} || [];
    return 0 unless ref($filter) eq 'ARRAY' && @$filter;
    return grep { lc($_) eq lc($cat) } @$filter;
}

sub site_receives {
    my ($self, $config, $msg) = @_;
    $config ||= {};
    $msg ||= {};
    my %watch = map { lc($_) => 1 } $self->emails_in(@{ $config->{email_addresses} || [] });
    return 0 unless %watch;
    my @got = $self->emails_in(
        $msg->{to}, $msg->{cc}, $msg->{delivered_to}, $msg->{envelope_to},
    );
    for my $e (@got) {
        return 1 if $watch{$e};
    }
    return 0;
}

sub emails_in {
    my ($self, @parts) = @_;
    my @out;
    my %seen;
    for my $part (@parts) {
        next unless defined $part;
        if (ref($part) eq 'ARRAY') {
            push @out, $self->emails_in(@$part);
            next;
        }
        while ($part =~ /([A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,})/ig) {
            my $e = lc $1;
            next if $seen{$e}++;
            push @out, $e;
        }
    }
    return @out;
}

sub lists_same {
    my ($self, $a, $b) = @_;
    my $left  = join ',', sort map { lc $_ } $self->emails_in(@{ $a || [] });
    my $right = join ',', sort map { lc $_ } $self->emails_in(@{ $b || [] });
    return $left eq $right;
}

sub _target_sites {
    my ($self, $sites, $only) = @_;
    if (defined $only && length $only) {
        return ($only);
    }
    return sort keys %{ $sites || {} };
}

sub _classified_file {
    my ($self, $c, $classifier) = @_;
    if ($c && $c->can('path_to')) {
        my $p = eval { $c->path_to('root', 'data', 'invoices', 'classified_invoices.json') };
        return "$p" if $p && -f "$p";
    }
    return File::Spec->catfile($classifier->{output_dir} || '', 'classified_invoices.json');
}

sub _read_json {
    my ($self, $c, $file) = @_;
    my $data;
    eval {
        open my $fh, '<', $file or die $!;
        local $/;
        $data = JSON->new->utf8->decode(<$fh>);
        close $fh;
    };
    if ($@ || ref($data) ne 'HASH') {
        $self->{logging}->log_with_details($c, 'error', __FILE__, __LINE__, 'apply',
            "parse $file: $@");
        return { ok => 0, error => "parse failed: $@" };
    }
    $data->{ok} = 1;
    return $data;
}

sub _apply_one {
    my ($self, $c, $schema, $classifier, $sitename, $config, $msg) = @_;
    my $mail_id = $msg->{id} || '';
    my ($from_email) = $self->emails_in($msg->{from});
    $from_email ||= '';
    unless ($self->_from_allowed($config, $from_email)) {
        return { id => $mail_id, reason => 'supplier_not_on_watch', email => $from_email };
    }
    my $supplier = $self->_supplier_for($schema, $sitename, $from_email);
    unless ($supplier) {
        return { id => $mail_id, reason => 'no_supplier', from => $msg->{from} || '' };
    }
    my $inv_no = $mail_id ? ('MAIL-' . substr($mail_id, 0, 16)) : undef;
    unless ($inv_no) {
        return { id => $mail_id, reason => 'no_mail_id' };
    }
    my $invoice = eval {
        $schema->resultset('Accounting::InventorySupplierInvoice')->search({
            sitename => $sitename, invoice_number => $inv_no,
        })->first;
    };
    if ($@) {
        $self->{logging}->log_with_details($c, 'error', __FILE__, __LINE__, 'apply',
            "invoice lookup: $@");
        return { id => $mail_id, reason => "lookup: $@" };
    }
    if ($invoice && lc($invoice->status || '') eq 'posted') {
        return { id => $mail_id, reason => 'already_posted', invoice_id => $invoice->id };
    }

    my $now = Comserv::Util::AppTime->now_utc;
    my $today = Comserv::Util::AppTime->today_utc_ymd;
    my $created_now = 0;
    unless ($invoice) {
        my $amount = $self->_amount_from($msg);
        my $notes = join("\n",
            'Draft from supplier-invoice mail. Stock is received only when every line matches an existing item. No GL post.',
            'mail_id=' . $mail_id,
            'from=' . ($msg->{from} || ''),
            'to=' . ($msg->{to} || ''),
            'subject=' . ($msg->{subject} || ''),
        );
        eval {
            $invoice = $schema->resultset('Accounting::InventorySupplierInvoice')->create({
                sitename       => $sitename,
                supplier_id    => $supplier->id,
                invoice_number => $inv_no,
                invoice_date   => $today,
                total_amount   => $amount,
                status         => 'draft',
                notes          => $notes,
                created_by     => ($c->session->{username} || 'mail-invoice'),
                created_at     => $now,
                updated_at     => $now,
            });
        };
        if ($@ || !$invoice) {
            $self->{logging}->log_with_details($c, 'error', __FILE__, __LINE__, 'apply',
                "create invoice $inv_no: $@");
            return { id => $mail_id, reason => "create: $@" };
        }
        $created_now = 1;
    }

    my $done = $self->_finish_invoice($c, $schema, $classifier, $invoice, $msg, $sitename, $supplier);
    $done->{id} = $mail_id;
    $done->{invoice_id} = $invoice->id;
    $done->{invoice_number} = $inv_no;
    $done->{created} = 1 if $created_now && !$done->{received};
    return $done;
}

sub _from_allowed {
    my ($self, $config, $from_email) = @_;
    my $suppliers = $config->{monitored_suppliers} || [];
    my $watch = $config->{email_addresses} || [];
    return 1 unless @$suppliers;
    # The setup page used to copy the mailbox list into this field. That is not a From filter.
    return 1 if $self->lists_same($suppliers, $watch);
    return 0 unless $from_email;
    return grep { lc($_) eq lc($from_email) } $self->emails_in(@$suppliers);
}

sub _supplier_for {
    my ($self, $schema, $sitename, $from_email) = @_;
    return unless $from_email;
    my @rows = eval {
        $schema->resultset('Accounting::InventorySupplier')->search({
            sitename => $sitename,
        })->all;
    };
    return if $@;
    for my $row (@rows) {
        my ($em) = $self->emails_in($row->email);
        return $row if $em && $em eq $from_email;
    }
    return;
}

sub _amount_from {
    my ($self, $msg) = @_;
    my $text = ($msg->{body_preview} || '') . ' ' . ($msg->{subject} || '');
    if ($text =~ /(?:total|amount|due)[^\d]{0,20}(\d+[\.,]\d{2})/i) {
        my $n = $1;
        $n =~ s/,/./;
        return $n;
    }
    return 0;
}

sub _finish_invoice {
    my ($self, $c, $schema, $classifier, $invoice, $msg, $sitename, $supplier) = @_;
    my $fail;
    my $result = { received => 0, created => 0, reason => '' };
    eval {
        $schema->txn_do(sub {
            my @existing = $invoice->lines->all;
            unless (@existing) {
                my $body = $classifier->message_body($msg);
                my @parsed = $classifier->_parse_invoice_line_items(
                    $body, $msg->{subject}, $msg->{from},
                );
                for my $line (@parsed) {
                    my $qty = 0 + ($line->{quantity} || 0);
                    next unless $qty > 0;
                    my $item = $self->_match_item($schema, $sitename, $supplier->id, $line);
                    my $cost = 0 + ($line->{price} || 0);
                    my $desc = $line->{name} || $line->{sku} || 'Mail invoice line';
                    $desc = substr($desc, 0, 250);
                    $invoice->create_related('lines', {
                        item_id     => $item ? $item->id : undef,
                        description => $desc,
                        quantity    => $qty,
                        unit_cost   => $cost,
                        line_total  => sprintf('%.2f', $qty * $cost),
                    });
                }
                @existing = $invoice->lines->all;
            }
            unless (@existing) {
                $result->{reason} = 'no_lines';
                $result->{created} = 1;
                return;
            }
            my $unmatched = grep { !$_->item_id } @existing;
            if ($unmatched) {
                $result->{reason} = 'unmatched_lines';
                $result->{unmatched} = $unmatched;
                $result->{created} = 1;
                return;
            }
            my $loc = $self->_default_location($schema, $sitename);
            my $ref = 'INV-' . ($invoice->invoice_number || $invoice->id);
            my $now = Comserv::Util::AppTime->now_utc;
            my $who = ($c->session && $c->session->{username}) || 'mail-invoice';
            for my $line (@existing) {
                my $line_ref = $ref . '-L' . $line->id;
                my $already = $schema->resultset('Accounting::InventoryTransaction')->search({
                    item_id          => $line->item_id,
                    transaction_type => 'receive',
                    reference_number => { -in => [ $ref, $line_ref ] },
                    sitename         => $sitename,
                })->count;
                next if $already;
                my $sl = $schema->resultset('Accounting::InventoryStockLevel')->find({
                    item_id => $line->item_id, location_id => $loc->id,
                });
                unless ($sl) {
                    $sl = $schema->resultset('Accounting::InventoryStockLevel')->create({
                        item_id           => $line->item_id,
                        location_id       => $loc->id,
                        quantity_on_hand  => 0,
                        quantity_reserved => 0,
                        quantity_on_order => 0,
                    });
                }
                my $old = 0 + ($sl->quantity_on_hand || 0);
                $sl->update({ quantity_on_hand => $old + $line->quantity });
                $schema->resultset('Accounting::InventoryTransaction')->create({
                    item_id          => $line->item_id,
                    location_id      => $loc->id,
                    transaction_type => 'receive',
                    quantity         => $line->quantity,
                    unit_cost        => $line->unit_cost,
                    reference_number => $line_ref,
                    sitename         => $sitename,
                    performed_by     => $who,
                    transaction_date => $now,
                    created_at       => $now,
                    notes            => 'Supplier invoice mail receive',
                });
            }
            $invoice->update({
                status     => 'posted',
                updated_at => $now,
                notes      => ($invoice->notes || '') . "\n[$now] Stock received from mail. No GL.",
            });
            $result->{received} = 1;
        });
    };
    if ($@) {
        $fail = $@;
        $self->{logging}->log_with_details($c, 'error', __FILE__, __LINE__, 'apply',
            "finish invoice " . ($invoice->id || '') . ": $fail");
        return { reason => "finish: $fail" };
    }
    return $result;
}

sub _match_item {
    my ($self, $schema, $sitename, $supplier_id, $line) = @_;
    my ($sku) = $self->_clean($line->{sku});
    if ($sku) {
        my $item = eval {
            $schema->resultset('Accounting::InventoryItem')->find({
                sitename => $sitename, sku => $sku,
            });
        };
        return $item if $item && !$@;
        if ($supplier_id) {
            my $link = eval {
                $schema->resultset('Accounting::InventoryItemSupplier')->search({
                    supplier_id  => $supplier_id,
                    supplier_sku => $sku,
                }, { rows => 1 })->first;
            };
            if ($link && !$@) {
                $item = eval { $schema->resultset('Accounting::InventoryItem')->find($link->item_id) };
                return $item if $item && lc($item->sitename || '') eq lc($sitename);
            }
        }
    }
    my ($name) = $self->_clean($line->{name});
    return unless $name && length($name) >= 3;
    my $item = eval {
        $schema->resultset('Accounting::InventoryItem')->search({
            sitename => $sitename,
            name     => $name,
        }, { rows => 1 })->first;
    };
    return $item if $item && !$@;
    return;
}

sub _clean {
    my ($self, $v) = @_;
    return unless defined $v;
    $v =~ s/^\s+|\s+$//g;
    return $v;
}

sub _default_location {
    my ($self, $schema, $sitename) = @_;
    my $loc = $schema->resultset('Accounting::InventoryLocation')->search({
        sitename => $sitename, name => 'Default',
    })->first;
    return $loc if $loc;
    return $schema->resultset('Accounting::InventoryLocation')->create({
        sitename => $sitename,
        name     => 'Default',
        status   => 'active',
    });
}

# Development core only. Other sites wait for their own Postgres database.
sub core_site {
    my ($self, $sitename) = @_;
    return grep { $_ eq ($sitename // '') } qw(3d CSC Shanta);
}

# Floor, not a turnover guess. One receipt must not become reorder_quantity.
# Cumin and cinnamon are the named exceptions (minimum 2, reorder 1).
sub reorder_floor {
    my ($self, $name) = @_;
    $name = '' unless defined $name;
    if ($name =~ /\b(?:cumin|cinnamon)\b/i) {
        return { reorder_point => 2, reorder_quantity => 1, spice => 1 };
    }
    return { reorder_point => 1, reorder_quantity => undef, spice => 0 };
}

sub update_line {
    my ($self, $c, %args) = @_;
    my $schema = eval { $c->model('DBEncy') };
    return { ok => 0, error => 'no database' } unless $schema;
    my $line = eval {
        $schema->resultset('Accounting::InventorySupplierInvoiceLine')->find($args{line_id});
    };
    if ($@) {
        $self->{logging}->log_with_details($c, 'error', __FILE__, __LINE__, 'update_line', "$@");
        return { ok => 0, error => 'Could not read that line.' };
    }
    return { ok => 0, error => 'Line not found.' } unless $line;

    my $inv = eval { $line->invoice };
    if ($@ || !$inv) {
        $self->{logging}->log_with_details($c, 'error', __FILE__, __LINE__, 'update_line',
            $@ || 'invoice missing');
        return { ok => 0, error => 'Invoice for that line was not found.' };
    }
    return { ok => 0, error => 'Line edits are only for 3d, CSC, and Shanta.' }
        unless $self->core_site($inv->sitename);

    if ($self->_line_already_received($schema, $inv, $line)) {
        return { ok => 0, error => 'That line was already received. Stock was not changed.' };
    }

    my $name = $args{description};
    $name = '' unless defined $name;
    $name =~ s/^\s+|\s+$//g;
    return { ok => 0, error => 'The line needs a name of at least 2 characters.' }
        unless length($name) >= 2;
    $name = substr($name, 0, 250);

    my $qty = $args{quantity};
    return { ok => 0, error => 'Quantity must be a number greater than zero.' }
        unless defined $qty && $qty =~ /^\d+(?:\.\d+)?$/ && 0+$qty > 0;
    my $cost = $args{unit_cost};
    $cost = 0 unless defined $cost && $cost ne '';
    return { ok => 0, error => 'Cost must be a number, zero or more.' }
        unless $cost =~ /^\d+(?:\.\d+)?$/;

    eval {
        $line->update({
            description => $name,
            quantity    => $qty,
            unit_cost   => $cost,
            line_total  => sprintf('%.2f', $qty * $cost),
        });
    };
    if ($@) {
        $self->{logging}->log_with_details($c, 'error', __FILE__, __LINE__, 'update_line', "$@");
        return { ok => 0, error => 'Could not save the line.' };
    }
    $self->{logging}->log_with_details($c, 'info', __FILE__, __LINE__, 'update_line',
        'line ' . $line->id . ' corrected. Stock not changed.');
    return { ok => 1 };
}

sub accept_invoice {
    my ($self, $c, %args) = @_;
    my $schema = eval { $c->model('DBEncy') };
    return { ok => 0, error => 'no database' } unless $schema;
    my $inv = eval {
        $schema->resultset('Accounting::InventorySupplierInvoice')->find($args{invoice_id});
    };
    if ($@) {
        $self->{logging}->log_with_details($c, 'error', __FILE__, __LINE__, 'accept_invoice', "$@");
        return { ok => 0, error => 'Could not read that invoice.' };
    }
    return { ok => 0, error => 'Invoice not found.' } unless $inv;
    my $site = $inv->sitename || '';
    return { ok => 0, error => 'Accept is only for 3d, CSC, and Shanta.' }
        unless $self->core_site($site);

    my @lines = eval { $inv->lines->all };
    if ($@) {
        $self->{logging}->log_with_details($c, 'error', __FILE__, __LINE__, 'accept_invoice', "$@");
        return { ok => 0, error => 'Could not read the invoice lines.' };
    }
    return { ok => 0, error => 'This invoice has no lines to accept.' } unless @lines;

    for my $line (@lines) {
        my $qty = 0 + ($line->quantity || 0);
        return { ok => 0, error => 'Line ' . $line->id . ' needs a quantity greater than zero.' }
            unless $qty > 0;
        my $name = $line->description || '';
        $name =~ s/^\s+|\s+$//g;
        return { ok => 0, error => 'Line ' . $line->id . ' needs an item name before accept.' }
            unless length($name) >= 2;
    }

    my $out = { ok => 1, created => 0, received => 0, already => 0 };
    eval {
        $schema->txn_do(sub {
            for my $line (@lines) {
                my $item = $line->item_id
                    ? $schema->resultset('Accounting::InventoryItem')->find($line->item_id)
                    : undef;
                unless ($item) {
                    $item = $self->_match_item($schema, $site, $inv->supplier_id, {
                        name => $line->description,
                    });
                }
                unless ($item) {
                    $item = $self->_create_from_line($c, $schema, $site, $line);
                    $out->{created}++;
                }
                if (!$line->item_id || $line->item_id != $item->id) {
                    $line->update({ item_id => $item->id });
                }
                $self->_apply_cost_and_min($item, $line);
            }
            my $recv = $self->_receive_lines($c, $schema, $inv, $site);
            $out->{received} = $recv->{received};
            $out->{already}  = $recv->{already};
        });
    };
    if ($@) {
        $self->{logging}->log_with_details($c, 'error', __FILE__, __LINE__, 'accept_invoice',
            'invoice ' . $inv->id . ": $@");
        return { ok => 0, error => 'Accept failed. Stock was not changed.' };
    }
    $self->{logging}->log_with_details($c, 'info', __FILE__, __LINE__, 'accept_invoice',
        "invoice " . $inv->id . " created=$out->{created} received=$out->{received} already=$out->{already} no GL");
    $out->{invoice_id} = $inv->id;
    return $out;
}

sub _create_from_line {
    my ($self, $c, $schema, $sitename, $line) = @_;
    my $name = $line->description || '';
    $name =~ s/^\s+|\s+$//g;
    $name = substr($name, 0, 255);
    my $rule = $self->reorder_floor($name);
    my $now  = Comserv::Util::AppTime->now_utc;
    my $who  = ($c->session && $c->session->{username}) || 'invoice-queue';
    my $cost = $line->unit_cost;
    $cost = undef unless defined $cost && "$cost" =~ /^\d+(?:\.\d+)?$/;
    return $schema->resultset('Accounting::InventoryItem')->create({
        sitename            => $sitename,
        sku                 => $self->_sku_for_line($schema, $sitename, $line),
        name                => $name,
        description         => $name,
        category            => $rule->{spice} ? 'spice' : undef,
        item_origin         => 'purchased',
        is_assemblable      => 0,
        is_consumable       => $rule->{spice} ? 1 : 0,
        unit_of_measure     => 'each',
        unit_cost           => $cost,
        reorder_point       => $rule->{reorder_point},
        reorder_quantity    => $rule->{reorder_quantity} || 0,
        status              => 'active',
        show_in_shop        => 0,
        hide_stock_count    => 0,
        list_in_marketplace => 0,
        notes               => 'Created from invoice queue accept. No GL.',
        created_by          => $who,
        created_at          => $now,
        updated_at          => $now,
    });
}

sub _sku_for_line {
    my ($self, $schema, $sitename, $line) = @_;
    my $base = 'QINV-' . $line->id;
    my $sku  = $base;
    my $n    = 1;
    while ($n < 20 && $schema->resultset('Accounting::InventoryItem')->find({
        sitename => $sitename, sku => $sku,
    })) {
        $n++;
        $sku = $base . '-' . $n;
    }
    return substr($sku, 0, 100);
}

sub _apply_cost_and_min {
    my ($self, $item, $line) = @_;
    my $rule = $self->reorder_floor($item->name || $line->description);
    my %set;
    my $cost = $line->unit_cost;
    if (defined $cost && "$cost" =~ /^\d+(?:\.\d+)?$/ && (0+$cost > 0 || !defined $item->unit_cost)) {
        $set{unit_cost} = $cost;
    }
    my $rp = $item->reorder_point;
    if (!defined $rp || "$rp" eq '' || 0+$rp < $rule->{reorder_point}) {
        $set{reorder_point} = $rule->{reorder_point};
    }
    if (defined $rule->{reorder_quantity}) {
        my $rq = $item->reorder_quantity;
        if (!defined $rq || "$rq" eq '' || 0+$rq == 0) {
            $set{reorder_quantity} = $rule->{reorder_quantity};
        }
    }
    if ($rule->{spice}) {
        $set{is_consumable} = 1 unless $item->is_consumable;
        $set{category} = 'spice' unless $item->category;
    }
    $item->update(\%set) if %set;
    return;
}

sub _line_ref {
    my ($self, $inv, $line) = @_;
    my $ref = 'INV-' . ($inv->invoice_number || $inv->id);
    return ($ref, $ref . '-L' . $line->id);
}

sub _line_already_received {
    my ($self, $schema, $inv, $line) = @_;
    return 0 unless $line->item_id;
    my ($ref, $line_ref) = $self->_line_ref($inv, $line);
    my $n = $schema->resultset('Accounting::InventoryTransaction')->search({
        item_id          => $line->item_id,
        transaction_type => 'receive',
        reference_number => { -in => [ $ref, $line_ref ] },
        sitename         => $inv->sitename,
    })->count;
    return $n ? 1 : 0;
}

# Same receive shape as automatic apply. No general-ledger post.
sub _receive_lines {
    my ($self, $c, $schema, $inv, $sitename) = @_;
    my $loc = $self->_default_location($schema, $sitename);
    my $now = Comserv::Util::AppTime->now_utc;
    my $who = ($c->session && $c->session->{username}) || 'invoice-queue';
    my ($received, $already) = (0, 0);
    for my $line ($inv->lines->all) {
        next unless $line->item_id;
        if ($self->_line_already_received($schema, $inv, $line)) {
            $already++;
            next;
        }
        my (undef, $line_ref) = $self->_line_ref($inv, $line);
        my $sl = $schema->resultset('Accounting::InventoryStockLevel')->find({
            item_id => $line->item_id, location_id => $loc->id,
        });
        unless ($sl) {
            $sl = $schema->resultset('Accounting::InventoryStockLevel')->create({
                item_id           => $line->item_id,
                location_id       => $loc->id,
                quantity_on_hand  => 0,
                quantity_reserved => 0,
                quantity_on_order => 0,
            });
        }
        my $old = 0 + ($sl->quantity_on_hand || 0);
        $sl->update({ quantity_on_hand => $old + $line->quantity });
        $schema->resultset('Accounting::InventoryTransaction')->create({
            item_id          => $line->item_id,
            location_id      => $loc->id,
            transaction_type => 'receive',
            quantity         => $line->quantity,
            unit_cost        => $line->unit_cost,
            reference_number => $line_ref,
            sitename         => $sitename,
            performed_by     => $who,
            transaction_date => $now,
            created_at       => $now,
            notes            => 'Invoice queue accept. No GL.',
        });
        $received++;
    }
    if ($received) {
        $inv->update({
            status     => 'posted',
            updated_at => $now,
            notes      => ($inv->notes || '') . "\n[$now] Accepted from invoice queue. Stock received. No GL.",
        });
    }
    return { received => $received, already => $already };
}

1;
