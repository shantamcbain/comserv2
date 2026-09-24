package Comserv::Util::MailInvoiceClassifier;
use strict;
use warnings;
use JSON;
use Email::Simple;
use Email::MIME;
use Mail::IMAPClient;
use Digest::SHA qw(sha256_hex);
use File::Spec;
use File::Path qw(make_path);
use File::Path;
use Try::Tiny;
use Comserv::Util::Logging;
use Comserv::Util::AppTime;

sub new {
    my ($class, %args) = @_;
    my $self = {
        logging => Comserv::Util::Logging->instance,
        output_dir => $args{output_dir} || '/home/shanta/.comserv/worktrees/InventoryAccounting/Comserv/Comserv/root/data/invoices',
    };
    return bless $self, $class;
}

sub classify_all_mail {
    my ($self, %args) = @_;
    my $source = $args{source} || 'maildir';
    my $imap_server = $args{imap_server} || 'localhost';
    my $imap_port = $args{imap_port} || 143;
    my $imap_ssl = $args{imap_ssl} || 0;
    my $imap_user = $args{imap_user} || 'shanta';
    my $imap_pass = $args{imap_pass} || '';
    my $output_file = $args{output_file} || File::Spec->catfile($self->{output_dir}, 'classified_invoices.json');
    my $first_run = $args{first_run} // 1;

    $self->{logging}->log_with_details(undef, 'info', __FILE__, __LINE__, 'classify_all_mail',
        "Starting mail classification. source=$source, first_run=$first_run");

    unless (-d $self->{output_dir}) {
        make_path($self->{output_dir});
    }

    my @messages;
    if ($source eq 'imap') {
        @messages = $self->_fetch_from_imap($imap_server, $imap_port, $imap_ssl, $imap_user, $imap_pass);
    } else {
        @messages = $self->_fetch_from_maildir();
    }

    my %classified;
    foreach my $msg (@messages) {
        my $category = $self->_classify_message($msg);
        push @{$classified{$category} //= []}, $msg;
    }

    my %result;
    $result{metadata} = {
        generated_at => Comserv::Util::AppTime->now_utc,
        source => $source,
        total_messages_scanned => scalar(@messages),
        first_run => $first_run,
        message_counts_by_category => {},
    };
    foreach my $cat (keys %classified) {
        $result{metadata}{message_counts_by_category}{$cat} = scalar @{$classified{$cat}};
    }
    $result{categories} = {};
    foreach my $cat (keys %classified) {
        $result{categories}{$cat} = {
            label => $self->_category_label($cat),
            sites => $self->_category_sites($cat),
            count => scalar @{$classified{$cat}},
            invoices => $classified{$cat},
        };
    }
    my @uncategorized = grep { !$_->{is_invoice} } @messages;
    if (@uncategorized) {
        $result{categories}{other} = {
            label => 'Other (non-invoice)',
            sites => ['all'],
            count => scalar @uncategorized,
            invoices => \@uncategorized,
        };
    }

    my $json = JSON->new->utf8->pretty->canonical(1);
    my $json_text = $json->encode(\%result);
    open my $fh, '>', $output_file or die "Cannot write $output_file: $!";
    print $fh $json_text;
    close $fh;

    $self->{logging}->log_with_details(undef, 'info', __FILE__, __LINE__, 'classify_all_mail',
        "Wrote $output_file. " . scalar(@messages) . " messages scanned");

    return \%result;
}

sub scan_for_invoices {
    my ($self, %args) = @_;
    my $source = $args{source} || 'maildir';
    my @messages;
    if ($source eq 'maildir') {
        @messages = $self->_fetch_from_maildir();
    } else {
        @messages = $self->_fetch_from_imap(
            $args{imap_server} || 'localhost',
            $args{imap_port} || 143,
            $args{imap_ssl} || 0,
            $args{imap_user} || 'shanta',
            $args{imap_pass} || ''
        );
    }
    my @invoices = grep { $_->{is_invoice} } @messages;
    $self->{logging}->log_with_details(undef, 'info', __FILE__, __LINE__, 'scan_for_invoices',
        "Scanned " . scalar(@messages) . " messages, found " . scalar(@invoices) . " invoices");
    return \@invoices;
}

sub _fetch_from_maildir {
    my ($self) = @_;
    my @messages;
    my @maildirs = ('/home/shanta/Maildir/new', '/home/shanta/Maildir/cur');
    foreach my $dir (@maildirs) {
        next unless -d $dir;
        opendir(my $dh, $dir);
        my @files = readdir($dh);
        closedir($dh);
        foreach my $file (@files) {
            next if $file =~ /^\./;
            my $path = File::Spec->catfile($dir, $file);
            next unless -f $path;
            try {
                open(my $fh, '<', $path) or die "Cannot read $path: $!";
                local $/;
                my $content = <$fh>;
                close($fh);
                my $msg = $self->_parse_message($content, $path);
                push @messages, $msg if $msg;
            } catch {
                $self->{logging}->log_with_details(undef, 'error', __FILE__, __LINE__, '_fetch_from_maildir',
                    "Failed to parse $path: $_");
            };
        }
    }
    $self->{logging}->log_with_details(undef, 'info', __FILE__, __LINE__, '_fetch_from_maildir',
        "Fetched " . scalar(@messages) . " messages from Maildir");
    return @messages;
}

sub _fetch_from_imap {
    my ($self, $server, $port, $ssl, $user, $pass) = @_;
    my @messages;
    try {
        my $client = Mail::IMAPClient->new(
            Server => $server, Port => $port, Ssl => $ssl,
            User => $user, Password => $pass, Timeout => 30,
        ) or die "Cannot connect: $!";
        my @folders = $client->folders;
        $self->{logging}->log_with_details(undef, 'info', __FILE__, __LINE__, '_fetch_from_imap',
            "IMAP $server:$port. Folders: " . join(', ', @folders));
        foreach my $folder (@folders) {
            try {
                $client->select($folder) or next;
                my @uids = $client->search('ALL');
                last if !@uids;
                if (scalar @uids > 1000) {
                    @uids = @uids[int($#uids - 999) .. $#uids];
                }
                foreach my $uid (@uids) {
                    try {
                        my $msg_str = $client->message_string($uid);
                        if ($msg_str) {
                            my $msg = $self->_parse_message($msg_str, "IMAP:$server:$folder:$uid");
                            push @messages, $msg if $msg;
                        }
                    } catch { };
                }
            } catch {
                $self->{logging}->log_with_details(undef, 'error', __FILE__, __LINE__, '_fetch_from_imap',
                    "Failed folder $folder: $_");
            };
        }
        $client->logout;
    } catch {
        $self->{logging}->log_with_details(undef, 'error', __FILE__, __LINE__, '_fetch_from_imap',
            "IMAP failed: $_");
    };
    $self->{logging}->log_with_details(undef, 'info', __FILE__, __LINE__, '_fetch_from_imap',
        "Fetched " . scalar(@messages) . " messages from IMAP");
    return @messages;
}

sub _parse_message {
    my ($self, $content, $source) = @_;
    return undef unless $content;
    my $msg;
    try {
        $msg = Email::Simple->new($content);
    } catch {
        try {
            my $em = Email::MIME->new($content);
            $msg = $em;
        } catch {
            return undef;
        };
    };
    my $from = $msg->header('From') || '';
    my $to = $msg->header('To') || '';
    my $subject = $msg->header('Subject') || '';
    my $date = $msg->header('Date') || '';
    my $body = '';
    try {
        if (ref $msg eq 'Email::MIME') {
            $body = $msg->body_str || '';
        } else {
            $body = $msg->body || '';
        }
    } catch { $body = ''; };
    if (!$body && ref $msg eq 'Email::MIME') {
        foreach my $part ($msg->parts) {
            my $ct = $part->content_type || '';
            if ($ct =~ m{text\/plain}i) {
                $body = $part->body_str || '';
                last;
            }
        }
    }
    my $body_lower = lc($body . ' ' . $subject);
    my $is_invoice = 0;
    foreach my $pattern (@{$self->_invoice_patterns}) {
        if ($body_lower =~ $pattern) { $is_invoice = 1; last; }
    }
    unless ($is_invoice) {
        foreach my $pattern (@{$self->_invoice_patterns}) {
            if ($subject =~ $pattern) { $is_invoice = 1; last; }
        }
    }
    return {
        id => sha256_hex($content . $source),
        source => $source,
        from => $from,
        to => $to,
        subject => $subject,
        date => $date,
        body_preview => substr($body, 0, 500),
        is_invoice => $is_invoice,
    };
}

sub _classify_message {
    my ($self, $msg) = @_;
    my $text = lc($msg->{subject} . ' ' . $msg->{body_preview} . ' ' . $msg->{from});
    return 'other' unless $msg->{is_invoice};

    my @cats = ('personal', 'csc_internet', 'hosting', 'domain', '3d_filament', 'hardware');
    foreach my $cat (@cats) {
        my $kw = $self->_category_keywords($cat);
        foreach my $pattern (@$kw) {
            if ($text =~ $pattern) { return $cat; }
        }
    }
    if ($msg->{from} =~ /csc\.computersystemconsulting\.ca/i) { return 'csc_internet'; }
    if ($msg->{from} =~ /hosting/i || $msg->{from} =~ /beemaster/i) { return 'hosting'; }
    if ($msg->{from} =~ /domain/i) { return 'domain'; }
    if ($msg->{from} =~ /filament/i || $msg->{from} =~ /print/i) { return '3d_filament'; }
    if ($msg->{from} =~ /hardware/i || $msg->{from} =~ /kobra/i || $msg->{from} =~ /flashforge/i) { return 'hardware'; }
    return 'other';
}

sub _category_label {
    my ($self, $cat) = @_;
    my %labels = (
        personal => 'Personal (Shanta)',
        csc_internet => 'CSC Internet',
        hosting => 'Hosting',
        domain => 'Domain Names',
        '3d_filament' => '3D Filament',
        hardware => 'Hardware',
        other => 'Other',
    );
    return $labels{$cat} || 'Other';
}

sub _category_sites {
    my ($self, $cat) = @_;
    my %sites = (
        personal => ['personal'],
        csc_internet => ['CSC'],
        hosting => ['CSC'],
        domain => ['CSC'],
        '3d_filament' => ['3d'],
        hardware => ['3d'],
        other => ['all'],
    );
    return $sites{$cat} || ['all'];
}

sub _invoice_patterns {
    return [
        qr/invoice/i, qr/receipt/i, qr/bill/i, qr/statement/i,
        qr/payment\s*due/i, qr/amount\s*due/i, qr/order\s*confirm/i,
        qr/order\s*summary/i, qr/purchase\s*order/i, qr/purchase\s*receipt/i,
        qr/total\s*amount/i, qr/subtotal/i, qr/gross\s*amount/i,
        qr/invoice\s*#/i, qr/inv[-_ ]?no/i, qr/inv?-?\s*\d+/i,
        qr/refund/i, qr/credit\s*note/i, qr/debit\s*note/i,
    ];
}

sub _category_keywords {
    my ($self, $cat) = @_;
    if ($cat eq 'personal') {
        return [qr/shanta/i, qr/my (order|invoice|receipt)/i, qr/personal/i, qr/individual/i, qr/self[- ]?service/i];
    } elsif ($cat eq 'csc_internet') {
        return [qr/internet/i, qr/broadband/i, qr/fiber/i, qr/ethernet/i, qr/network\s*access/i];
    } elsif ($cat eq 'hosting') {
        return [qr/hosting/i, qr/web.?host/i, qr/server.?host/i, qr/vps\s*(plan|service)/i, qr/dedicated\s*server/i, qr/cloud.*server/i];
    } elsif ($cat eq 'domain') {
        return [qr/domain/i, qr/domain\s*(registration|renew|transfer|name)/i, qr/whois/i, qr/TLD/i];
    } elsif ($cat eq '3d_filament') {
        return [qr/filament/i, qr/pla/i, qr/abs/i, qr/petg/i, qr/asa/i, qr/spool/i, qr/colorfabb/i, qr/inland/i, qr/overture/i];
    } elsif ($cat eq 'hardware') {
        return [qr/hardware/i, qr/parts/i, qr/components/i, qr/equipment/i, qr/kobra/i, qr/flashforge/i, qr/ace/i];
    }
    return [];
}

# Create draft AP rows from classified mail. Never posts GL.
# Matches InventorySupplier.email to From:. Skips unmatched + personal.
sub draft_supplier_invoices {
    my ($self, $c, %args) = @_;
    my $sitename = $args{sitename} || ($c && $c->session->{SiteName}) || 'CSC';
    my $file = $args{file} || File::Spec->catfile($self->{output_dir}, 'classified_invoices.json');
    my $schema = $c->model('DBEncy');
    my @created;
    my @skipped;
    unless (-f $file) {
        $self->{logging}->log_with_details($c, 'warn', __FILE__, __LINE__, 'draft_supplier_invoices',
            "no classified file $file");
        return { ok => 0, error => "classified file missing: $file" };
    }
    my $data;
    eval {
        open my $fh, '<', $file or die $!;
        local $/;
        $data = JSON->new->utf8->decode(<$fh>);
        close $fh;
    };
    if ($@ || ref($data) ne 'HASH') {
        $self->{logging}->log_with_details($c, 'error', __FILE__, __LINE__, 'draft_supplier_invoices',
            "parse: $@");
        return { ok => 0, error => "parse failed: $@" };
    }
    my $now  = Comserv::Util::AppTime->now_utc;
    my $today = Comserv::Util::AppTime->today_utc_ymd;
    my $cats = $data->{categories} || {};
    for my $cat (keys %$cats) {
        next if $cat eq 'personal';
        my $block = $cats->{$cat} || {};
        my $sites = $block->{sites} || [];
        if (@$sites && !grep { $_ eq 'all' || lc($_) eq lc($sitename) } @$sites) {
            next;
        }
        for my $inv (@{ $block->{invoices} || [] }) {
            next unless $inv && $inv->{is_invoice};
            my $mail_id = $inv->{id} || '';
            my $inv_no  = $mail_id ? ('MAIL-' . substr($mail_id, 0, 16)) : undef;
            if ($inv_no) {
                my $exists = eval {
                    $schema->resultset('Accounting::InventorySupplierInvoice')->search({
                        sitename => $sitename, invoice_number => $inv_no,
                    })->first;
                };
                if ($exists) {
                    push @skipped, { id => $mail_id, reason => 'exists' };
                    next;
                }
            }
            my $from = $inv->{from} || '';
            my ($email) = $from =~ /<([^>]+)>/;
            $email ||= $from;
            $email =~ s/^\s+|\s+$//g;
            my $supplier;
            if ($email && $email =~ /@/) {
                $supplier = eval {
                    $schema->resultset('Accounting::InventorySupplier')->search({
                        sitename => $sitename,
                        email    => { -like => '%' . $email . '%' },
                    }, { rows => 1 })->first;
                };
            }
            unless ($supplier) {
                push @skipped, { id => $mail_id, reason => 'no_supplier', from => $from };
                next;
            }
            my $amount = 0;
            if (($inv->{body_preview} || '') =~ /(?:total|amount|due)[^\d]{0,20}(\d+[\.,]\d{2})/i) {
                ($amount = $1) =~ s/,/./;
            }
            my $notes = join("\n",
                'Draft from mail classifier. No GL post.',
                'mail_id=' . $mail_id,
                'from=' . $from,
                'subject=' . ($inv->{subject} || ''),
                'date=' . ($inv->{date} || ''),
            );
            my $row;
            eval {
                $row = $schema->resultset('Accounting::InventorySupplierInvoice')->create({
                    sitename       => $sitename,
                    supplier_id    => $supplier->id,
                    invoice_number => $inv_no,
                    invoice_date   => $today,
                    total_amount   => $amount,
                    status         => 'draft',
                    notes          => $notes,
                    created_by     => ($c->session->{username} || 'hermes-agent'),
                    created_at     => $now,
                    updated_at     => $now,
                });
            };
            if ($@ || !$row) {
                $self->{logging}->log_with_details($c, 'error', __FILE__, __LINE__, 'draft_supplier_invoices',
                    "create failed: $@");
                push @skipped, { id => $mail_id, reason => "$@" };
                next;
            }
            push @created, { invoice_id => $row->id, invoice_number => $inv_no, supplier_id => $supplier->id, amount => $amount };
        }
    }
    $self->{logging}->log_with_details($c, 'info', __FILE__, __LINE__, 'draft_supplier_invoices',
        "sitename=$sitename created=" . scalar(@created) . " skipped=" . scalar(@skipped));
    return { ok => 1, created => \@created, skipped => \@skipped };
}

1;
