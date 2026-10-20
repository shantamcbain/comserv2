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

sub monitor_config_file {
    my ($self) = @_;
    my $root = $self->{output_dir} || '';
    $root =~ s{/data/invoices/?$}{};
    return File::Spec->catfile($root, 'config', 'email_invoice_monitor.json');
}

sub _default_monitor_config {
    return {
        sites => {
            CSC => {
                email_addresses     => ['shanta@forager.com', 'paypal@forager.com', 'patrion@forager.com', 'aica@forager.com'],
                monitored_suppliers => ['shanta@forager.com', 'paypal@forager.com', 'patrion@forager.com', 'aica@forager.com'],
                category_filter     => ['csc_internet', 'hosting', 'domain'],
            },
            '3d' => {
                email_addresses     => ['mater3d@forager.com'],
                monitored_suppliers => ['mater3d@forager.com'],
                category_filter     => ['3d_filament', 'hardware'],
            },
        },
    };
}

sub load_monitor_config {
    my ($self) = @_;
    my $file = $self->monitor_config_file;
    my $defaults = $self->_default_monitor_config;
    return $defaults unless -f $file;
    my $data;
    eval {
        open my $fh, '<', $file or die $!;
        local $/;
        $data = JSON->new->utf8->decode(<$fh>);
        close $fh;
    };
    return $defaults if $@ || ref($data) ne 'HASH' || ref($data->{sites}) ne 'HASH';
    return $data;
}

sub save_monitor_config {
    my ($self, $data) = @_;
    return 'config is not a hash' unless ref($data) eq 'HASH';
    my $file = $self->monitor_config_file;
    my $dir = File::Spec->catdir((File::Spec->splitpath($file))[1] ? (File::Spec->splitpath($file))[1] : ());
    # splitpath returns volume, dir, file — dir may be empty-looking but includes trailing slash
    my (undef, $dirname, undef) = File::Spec->splitpath($file);
    eval { make_path($dirname) if $dirname && !-d $dirname };
    eval {
        open my $fh, '>', $file or die $!;
        print $fh JSON->new->utf8->pretty->canonical->encode($data);
        close $fh;
    };
    return $@ if $@;
    return;
}

sub config_for_site {
    my ($self, $all, $sitename) = @_;
    $all ||= $self->load_monitor_config;
    my $sites = $all->{sites} || {};
    return $sites->{$sitename} if $sites->{$sitename};
    for my $key (keys %$sites) {
        return $sites->{$key} if lc($key) eq lc($sitename || '');
    }
    return { email_addresses => [], monitored_suppliers => [], category_filter => [] };
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

    my @messages = $self->_fetch_from_maildir();
    if ($source eq 'imap') {
        push @messages, $self->_fetch_from_imap($imap_server, $imap_port, $imap_ssl, $imap_user, $imap_pass);
    } elsif ($source eq 'auto' || $source eq 'maildir') {
        push @messages, $self->fetch_imap_accounts($args{accounts} || []);
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
        local_maildir => join(', ', $self->system_maildirs()),
        mailbox_logins => $self->{mailbox_log} || [],
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

sub system_maildirs {
    my ($self) = @_;
    my @dirs;
    my $home = $ENV{HOME} || '';
    if ($home) {
        my $root = File::Spec->catdir($home, 'Maildir');
        for my $sub (qw(new cur)) {
            my $dir = File::Spec->catdir($root, $sub);
            push @dirs, $dir if -d $dir;
        }
    }
    return @dirs;
}

sub _fetch_from_maildir {
    my ($self) = @_;
    my @messages;
    my @maildirs = $self->system_maildirs();
    unless (@maildirs) {
        $self->{logging}->log_with_details(undef, 'info', __FILE__, __LINE__, '_fetch_from_maildir',
            'No system mail dir on this host. Use a configured mail server for addresses that are not delivered here.');
        return @messages;
    }
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

sub accounts_for_site {
    my ($self, $c, $sitename) = @_;
    my $note = '';
    return ([], 'No request context') unless $c && $c->can('model');
    my $rs = eval { $c->model('DBEncy')->resultset('UserMailbox') };
    unless ($rs) {
        return ([], 'Mailbox table is not loaded. Run Schema Compare, then save the mail server again.');
    }
    my $ready = eval { $rs->search({}, { rows => 1 })->count; 1 };
    unless ($ready) {
        $self->{logging}->log_with_details($c, 'warn', __FILE__, __LINE__, 'accounts_for_site',
            'user_mailboxes is not available yet. Run Schema Compare before saving a mail server.');
        return ([], 'Mailbox table is not created yet. Run Schema Compare, then save the mail server.');
    }
    my $has_folders = $self->_mailbox_has_folders($rs);
    my @rows = eval { $rs->search({ sitename => $sitename },
        ($has_folders ? () : { columns => [ grep { $_ ne 'imap_folders' } $rs->result_source->columns ] }))->all };
    if ($@) {
        $self->{logging}->log_with_details($c, 'error', __FILE__, __LINE__, 'accounts_for_site', "Mailbox lookup failed: $@");
        return ([], 'Could not read saved mail servers.');
    }
    my $enc = do { require Comserv::Util::Encryption; Comserv::Util::Encryption->new() };
    my @accounts;
    for my $row (@rows) {
        my $cipher = $row->password_enc // '';
        next unless $cipher && $row->imap_host;
        my $password = eval { $enc->decrypt($cipher, 'mail') };
        next unless defined $password && $password ne '';
        push @accounts, {
            email_address  => $row->email_address,
            login_username => $row->login_username || $row->email_address,
            password       => $password,
            imap_host      => $row->imap_host,
            imap_port      => $row->imap_port || 993,
            imap_security  => $row->imap_security || 'ssl',
            imap_folders   => ($has_folders ? $row->get_column('imap_folders') : undef),
        };
    }
    $note = @accounts
        ? scalar(@accounts) . ' mail server(s) configured for this site'
        : 'No mail server saved for this site. Local mail dir is used only if it exists on this computer.';
    return (\@accounts, $note);
}

sub mailbox_summaries {
    my ($self, $c, $sitename) = @_;
    return ([], 'No request context') unless $c && $c->can('model');
    my $rs = eval { $c->model('DBEncy')->resultset('UserMailbox') };
    return ([], 'Mailbox table is not loaded. Run Schema Compare, then save the mail server again.') unless $rs;
    my $ready = eval { $rs->search({}, { rows => 1 })->count; 1 };
    return ([], 'Mailbox table is not created yet. Run Schema Compare, then save the mail server.') unless $ready;
    my @rows = eval {
        $rs->search({ sitename => $sitename }, { order_by => 'email_address', %{ $self->_mb_attrs($rs) } })->all;
    };
    return ([], 'Could not read saved mail servers.') if $@;
    my @out;
    for my $row (@rows) {
        push @out, {
            email_address => $row->email_address,
            login_username => $row->login_username,
            imap_host => $row->imap_host,
            imap_port => $row->imap_port,
            imap_security => $row->imap_security,
            has_password => ($row->password_enc ? 1 : 0),
        };
    }
    return (\@out, '');
}

sub save_mailbox {
    my ($self, $c, %m) = @_;
    my $sitename = $m{sitename} || '';
    return 'No site in session.' unless $sitename;
    my $email = lc($m{email_address} || '');
    $email =~ s/^\s+|\s+$//g;
    return 'Enter the mailbox address, like shanta@usbm.ca.' unless $email =~ /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
    my $host = lc($m{imap_host} || '');
    $host =~ s/^\s+|\s+$//g;
    return 'Enter the mail server host name.' unless $host =~ /^[a-z0-9.\-]{3,253}$/;
    my $port = $m{imap_port} || 993;
    return 'Mail server port must be a number.' unless $port =~ /^\d{1,5}$/ && $port > 0 && $port < 65536;
    my $security = lc($m{imap_security} || 'ssl');
    $security = 'ssl' unless $security =~ /^(ssl|starttls|none)$/;
    my $login = $m{login_username};
    $login = $email unless defined $login && $login =~ /\S/;
    $login =~ s/^\s+|\s+$//g;

    my $rs = eval { $c->model('DBEncy')->resultset('UserMailbox') };
    return 'Mailbox table is not loaded. Run Schema Compare, then save again.' unless $rs;
    my $ready = eval { $rs->search({}, { rows => 1 })->count; 1 };
    return 'Mailbox table is not created yet. Run Schema Compare, then save again.' unless $ready;

    my $existing = eval { $rs->search({ sitename => $sitename, email_address => $email }, $self->_mb_attrs($rs))->first };
    return "Could not read the mailbox row: $@" if $@;
    my $password = $m{password} // '';
    $password =~ s/^\s+|\s+$//g;
    my $cipher;
    if ($password ne '') {
        my $enc = do { require Comserv::Util::Encryption; Comserv::Util::Encryption->new() };
        $cipher = eval { $enc->encrypt($password, 'mail') };
        return 'Could not encrypt the mailbox password.' unless $cipher;
    } elsif ($existing && $existing->password_enc) {
        $cipher = $existing->password_enc;
    } else {
        return 'Enter the mailbox password. It is stored encrypted and is not written to the watch-list file.';
    }

    require Comserv::Util::AppTime;
    my $now = Comserv::Util::AppTime->now_utc;
    my $row = eval {
        $rs->update_or_create({
            sitename       => $sitename,
            email_address  => $email,
            login_username => $login,
            password_enc   => $cipher,
            imap_host      => $host,
            imap_port      => $port + 0,
            imap_security  => $security,
            ( $self->_mailbox_has_folders($rs) ? ( imap_folders => $self->clean_folders($m{imap_folders}) ) : () ),
            user_id        => $c->session->{user_id},
            updated_at     => $now,
            ($existing ? () : (created_at => $now)),
        }, { key => 'user_mailboxes_email_site' });
    };
    if ($@ || !$row) {
        my $err = $@ || 'save failed';
        $err =~ s/\s+/ /g;
        $self->{logging}->log_with_details($c, 'error', __FILE__, __LINE__, 'save_mailbox',
            "Could not save mailbox $email at $host: " . substr($err, 0, 180));
        return 'Could not save the mail server.';
    }
    $self->{logging}->log_with_details($c, 'info', __FILE__, __LINE__, 'save_mailbox',
        "Saved mail server for $email at $host:$port ($security) on $sitename");

    my $all = $self->load_monitor_config;
    my $cfg = $self->config_for_site($all, $sitename);
    my @emails = @{ $cfg->{email_addresses} || [] };
    push @emails, $email unless grep { lc($_) eq $email } @emails;
    $all->{sites}{$sitename} = {
        %$cfg,
        email_addresses => \@emails,
    };
    my $cfg_err = $self->save_monitor_config($all);
    return "Mail server saved, but the watch list could not be updated: $cfg_err" if $cfg_err;
    return undef;
}

sub delete_mailbox {
    my ($self, $c, $sitename, $email) = @_;
    $email = lc($email || '');
    $email =~ s/^\s+|\s+$//g;
    return 'No address to remove.' unless $email && $sitename;
    my $rs = eval { $c->model('DBEncy')->resultset('UserMailbox') };
    return 'Mailbox table is not loaded.' unless $rs;
    my $row = eval { $rs->search({ sitename => $sitename, email_address => $email }, $self->_mb_attrs($rs))->first };
    return "Could not read the mailbox row: $@" if $@;
    return 'That address is not on the mail-server list.' unless $row;
    eval { $row->delete };
    return 'Could not remove that mail server.' if $@;
    $self->{logging}->log_with_details($c, 'info', __FILE__, __LINE__, 'delete_mailbox',
        "Removed mail server $email for $sitename");
    return undef;
}

sub fetch_imap_accounts {
    my ($self, $accounts) = @_;
    $accounts ||= [];
    my @messages;
    $self->{mailbox_log} = [];
    for my $acct (@$accounts) {
        my $label = ($acct->{email_address} || $acct->{login_username} || '') . ' @ ' . ($acct->{imap_host} || '');
        unless ($acct->{imap_host} && $acct->{login_username} && $acct->{password}) {
            push @{$self->{mailbox_log}}, {
                email_address => $acct->{email_address} || '',
                imap_host => $acct->{imap_host} || '',
                imap_port => $acct->{imap_port} || '',
                ok => 0,
                fetched => 0,
                error => 'Missing host, login, or password',
            };
            next;
        }
        my ($got, $err) = $self->_fetch_inbox($acct);
        my $n = $got ? scalar(@$got) : 0;
        push @{$self->{mailbox_log}}, {
            email_address => $acct->{email_address} || $acct->{login_username},
            imap_host => $acct->{imap_host},
            imap_port => $acct->{imap_port} || 993,
            ok => $err ? 0 : 1,
            fetched => $n,
            error => $err || '',
        };
        $self->{logging}->log_with_details(undef, $err ? 'error' : 'info', __FILE__, __LINE__, 'fetch_imap_accounts',
            ($err ? "Login failed for $label: $err" : "Login ok for $label. Fetched $n messages"));
        push @messages, @$got if $got && @$got;
    }
    return @messages;
}

sub _fetch_inbox {
    my ($self, $acct) = @_;
    my @messages;
    try {
        require Mail::IMAPClient;
        my %opt = (
            Server  => $acct->{imap_host},
            Port    => $acct->{imap_port} || 993,
            Timeout => 20,
            Uid     => 1,
            Peek    => 1,
        );
        my $security = lc($acct->{imap_security} || 'ssl');
        $opt{Ssl} = 1 if $security eq 'ssl';
        $opt{Starttls} = 1 if $security eq 'starttls';
        my $imap = Mail::IMAPClient->new(%opt);
        die "could not connect\n" unless $imap && $imap->IsConnected;
        $imap->User($acct->{login_username});
        $imap->Password($acct->{password});
        die "login rejected\n" unless $imap->login;
        my $sep = eval { $imap->separator } || '/';
        my $opened = 0;
        for my $folder (@{ $self->folder_list($acct->{imap_folders}) }) {
            my @try = ($folder);
            (my $alt = $folder) =~ s{[/.]}{$sep}g;
            push @try, $alt if $alt ne $folder;
            my ($ok) = grep { $imap->select($_) } @try;
            unless ($ok) {
                $self->{logging}->log_with_details(undef, 'warn', __FILE__, __LINE__, '_fetch_inbox',
                    "Folder not found: $folder");
                next;
            }
            $opened++;
            my @uids = $imap->messages or ();
            @uids = splice(@uids, -200) if @uids > 200 && $ok =~ /^INBOX$/i;   # subfolders: read all
            for my $uid (@uids) {
                my $content = $imap->message_string($uid);
                next unless $content;
                my $msg = $self->_parse_message($content,
                    ($acct->{email_address} || $acct->{login_username}) . ($ok =~ /^INBOX$/i ? '' : ":$ok"));
                push @messages, $msg if $msg;
            }
        }
        die "could not open any folder\n" unless $opened;
        $imap->logout;
    } catch {
        my $err = $_;
        $err =~ s/\s+/ /g;
        $err =~ s/\bpassword\b/[redacted]/ig;
        $self->{logging}->log_with_details(undef, 'error', __FILE__, __LINE__, '_fetch_inbox',
            'Mail server read failed for ' . ($acct->{email_address} || $acct->{login_username})
            . ' at ' . $acct->{imap_host} . ': ' . substr($err, 0, 180));
        return ([], substr($err, 0, 180));
    };
    return (\@messages, '');
}

# Pure: "INBOX, INBOX/coop" -> ['INBOX','INBOX/coop']; blank -> ['INBOX'].
sub folder_list {
    my ($self, $spec) = @_;
    my @f = grep { length } map { s/^\s+|\s+$//gr } split /,/, ($spec // '');
    return @f ? \@f : ['INBOX'];
}

# Pure: sanitize the folder setting (letters, digits, space, . / _ - and commas only).
sub clean_folders {
    my ($self, $spec) = @_;
    my @f = grep { /^[\w .\/\-&]{1,100}$/ } map { s/^\s+|\s+$//gr } split /,/, ($spec // '');
    return @f ? join(', ', @f) : undef;
}

# Select attrs that skip imap_folders until Schema Compare adds it.
sub _mb_attrs {
    my ($self, $rs) = @_;
    return $self->_mailbox_has_folders($rs) ? {} : { columns => [ grep { $_ ne 'imap_folders' } $rs->result_source->columns ] };
}

sub _mailbox_has_folders {
    my ($self, $rs) = @_;
    return $self->{_has_folders} //= (eval { $rs->search({}, { columns => ['imap_folders'], rows => 1 })->first; 1 } ? 1 : 0);
}

# ---- Square receipt (HTML) parser -------------------------------------------
# Square's text/plain part only says "You paid $X"; the items are in the HTML.
sub html_lines {
    my ($self, $h) = @_;
    return [] unless defined $h && length $h;
    require HTML::Entities;
    $h =~ s{<(style|script)\b.*?</\1>}{}gis;
    $h =~ s{<br\s*/?>|</(?:p|div|tr|td|th|li|h\d)>}{\n}gi;
    $h =~ s/<[^>]+>//g;
    $h = HTML::Entities::decode_entities($h);
    return [ grep { length } map { s/^\s+|\s+$//gr } split /\n/, $h ];
}

my $MONEY = qr/^-?\$(\d+(?:,\d{3})*\.\d{2})$/;
sub _money { my $v = shift; $v =~ s/,//g; return 0 + $v }

# Returns { code, items => [{name,qty,uom,unit_price,line_total,reg_price,discount}], subtotal, gst, total, line_sum }
# or undef when the HTML is not a Square itemized receipt.
sub parse_square_receipt {
    my ($self, $html) = @_;
    my $L = ref $html ? $html : $self->html_lines($html);
    my ($code) = map { substr($_, 1) } grep { /^#\w{4}$/ } @$L;
    return undef unless $code;
    my $i = 0;
    $i++ while $i < @$L && $L->[$i] !~ $MONEY;
    return undef if $i >= @$L;
    $i++;
    $i += 2 if $i < @$L && $L->[$i] =~ /^#\w{4}$/;    # newer layout repeats #code + date
    my @items;
    while ($i < @$L) {
        my $l = $L->[$i];
        last if $l =~ /^(?:(?:purchase )?subtotal|total)$/i;
        my $cur = @items ? $items[-1] : undef;
        if ($l =~ $MONEY) {
            $cur->{line_total} = _money($1) if $cur && !defined $cur->{line_total};
        } elsif ($l =~ /^reg price/i) {
            (my $v = $l) =~ s/[^\d.]//g;
            if (!length $v && $i + 1 < @$L && $L->[$i + 1] =~ $MONEY) { $i++; $v = $1 }
            $cur->{reg_price} = _money($v) if $cur && length $v;
        } elsif ($l =~ /^Discount:\s*(.*)/) {
            $cur->{discount} = $1 if $cur;
        } elsif ($l =~ /^\(-?\$[\d.,]+\)$/) {
        } elsif ($l =~ /^([\d.]+)\s*(lb|kg|g)\s*@\s*\$([\d.]+)/) {
            @{$cur}{qw(qty uom unit_price)} = (0 + $1, $2, 0 + $3) if $cur;
        } elsif ($l =~ /^\(\$([\d.]+) ea\.\)$/) {
            $cur->{unit_price} = 0 + $1 if $cur;
        } elsif ($l =~ /^\(/) {
            push @{ $cur->{notes} }, $l if $cur;
        } else {
            my ($n, $q) = $l =~ /^(.*?)\s*[\x{00d7}x]\s*(\d+)$/ ? ($1, $2) : ($l, 1);
            $n =~ s/\s{2,}/ /g;
            push @items, { name => $n, qty => 0 + $q, uom => 'each' };
        }
        $i++;
    }
    @items = grep { defined $_->{line_total} } @items;
    return undef unless @items;
    my $after = sub {
        my $re = shift;
        for my $j ($i - 1 .. $#$L - 1) {
            return _money($1) if $L->[$j] =~ $re && $L->[$j + 1] =~ $MONEY;
        }
        return undef;
    };
    my %r = (code => $code, items => \@items,
        subtotal => $after->(qr/^(?:purchase )?subtotal$/i), gst => $after->(qr/^GST/), total => $after->(qr/^total$/i));
    for my $it (@items) {
        $it->{unit_price} //= $it->{qty} ? sprintf('%.4f', $it->{line_total} / $it->{qty}) + 0 : undef;
    }
    my $sum = 0; $sum += $_->{line_total} for @items;
    $r{line_sum} = sprintf('%.2f', $sum) + 0;
    $r{sum_ok} = !defined $r{subtotal} || abs($sum - $r{subtotal}) < 0.02 ? 1 : 0;
    return \%r;
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
    my $cc = $msg->header('Cc') || '';
    my $delivered_to = $msg->header('Delivered-To') || $msg->header('X-Original-To') || '';
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
    my $square;
    my $mime = $from =~ /squareup\.com/i ? eval { require Email::MIME; Email::MIME->new($content) } : undef;
    if ($mime) {
        my $html = '';
        for my $part ($mime->subparts ? $mime->subparts : ($mime)) {
            for my $p ($part->subparts ? $part->subparts : ($part)) {
                if (($p->content_type || '') =~ m{text/html}i) { $html = eval { $p->body_str } // ''; last }
            }
            last if length $html;
        }
        $square = $self->parse_square_receipt($html) if length $html;
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
        cc => $cc,
        delivered_to => $delivered_to,
        subject => $subject,
        date => $date,
        body_preview => substr($body, 0, 4000),
        is_invoice => ($square ? 1 : $is_invoice),
        ($square ? (square_receipt => $square, line_items => $square->{items}) : ()),
    };
}

# Full body when the source file is still on disk. Classified JSON only keeps a preview.
sub message_body {
    my ($self, $inv) = @_;
    $inv ||= {};
    my $src = $inv->{source} || '';
    if ($src && $src !~ /^IMAP:/ && -f $src && -s $src < 1_500_000) {
        my $text;
        eval {
            open my $fh, '<:raw', $src or die $!;
            local $/;
            my $raw = <$fh>;
            close $fh;
            $text = $self->_body_from_raw($raw);
        };
        if ($@) {
            $self->{logging}->log_with_details(undef, 'warn', __FILE__, __LINE__, 'message_body',
                "Could not re-read $src: $@");
        } elsif (defined $text && length $text) {
            return substr($text, 0, 12000);
        }
    }
    return $inv->{body_preview} || '';
}

sub _body_from_raw {
    my ($self, $raw) = @_;
    return '' unless defined $raw && length $raw;
    my $body = '';
    my $mime;
    eval { $mime = Email::MIME->new($raw); };
    if ($@) {
        $self->{logging}->log_with_details(undef, 'warn', __FILE__, __LINE__, '_body_from_raw',
            "MIME parse failed: $@");
    }
    if ($mime) {
        eval { $body = $mime->body_str || ''; };
        if ($@) {
            $self->{logging}->log_with_details(undef, 'warn', __FILE__, __LINE__, '_body_from_raw',
                "body_str failed: $@");
            $body = '';
        }
        if (!$body) {
            foreach my $part ($mime->parts) {
                my $ct = $part->content_type || '';
                next unless $ct =~ m{text/plain}i;
                my $part_body = '';
                eval { $part_body = $part->body_str || ''; };
                if ($@) {
                    $self->{logging}->log_with_details(undef, 'warn', __FILE__, __LINE__, '_body_from_raw',
                        "part body failed: $@");
                    next;
                }
                if (length $part_body) {
                    $body = $part_body;
                    last;
                }
            }
        }
        return $body if length $body;
    }
    my $simple;
    eval { $simple = Email::Simple->new($raw); };
    if ($@ || !$simple) {
        $self->{logging}->log_with_details(undef, 'warn', __FILE__, __LINE__, '_body_from_raw',
            "simple parse failed: " . ($@ || 'no message'));
        return '';
    }
    my $simple_body = '';
    eval { $simple_body = $simple->body || ''; };
    if ($@) {
        $self->{logging}->log_with_details(undef, 'warn', __FILE__, __LINE__, '_body_from_raw',
            "simple body failed: $@");
        return '';
    }
    return $simple_body;
}

sub _classify_message {
    my ($self, $msg) = @_;
    my $text = lc($msg->{subject} . ' ' . $msg->{body_preview} . ' ' . $msg->{from});
    return 'other' unless $msg->{is_invoice};

    return 'grocery' if $msg->{square_receipt};
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
        grocery => 'Groceries (Square receipts)',
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
        grocery => ['Shanta'],
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

# Line item parsing for invoice emails
sub _parse_invoice_line_items {
    my ($self, $body_preview, $subject, $from) = @_;
    return () unless $body_preview;
    
    my @line_items;
    my $text = $body_preview;
    
    # Clean up the text
    $text =~ s/\s+/ /g;
    $text =~ s/\n/ /g;
    
    # Try to extract line items using various patterns
    # Pattern 1: "SKU: NAME - QUANTITY x PRICE"
    while ($text =~ /([A-Z]+-\w+)\s*:\s*([^-]+?)\s*-\s*(\d+(?:\.\d+)?)\s*x\s*(\d+(?:\.\d+)?)/gi) {
        my ($sku, $name, $qty, $price) = ($1, $2, $3, $4);
        push @line_items, {
            sku => $sku,
            name => $name,
            quantity => $qty,
            price => $price,
            source => 'email_parsing',
        };
    }
    
    # Pattern 2: "QUANTITY x NAME (SKU) - $PRICE"
    while ($text =~ /(\d+(?:\.\d+)?)\s*x\s*([A-Za-z0-9\s]+?)\s*\((\w+-\w+)\)\s*-\s*\$(\d+(?:\.\d+)?)/gi) {
        my ($qty, $name, $sku, $price) = ($1, $2, $3, $4);
        push @line_items, {
            sku => $sku,
            name => $name,
            quantity => $qty,
            price => $price,
            source => 'email_parsing',
        };
    }
    
    # Pattern 3: "NAME SKU QUANTITY $PRICE"
    while ($text =~ /([A-Za-z0-9\s]+?)\s+(\w+-\w+)\s+(\d+(?:\.\d+)?)\s*\$(\d+(?:\.\d+)?)/gi) {
        my ($name, $sku, $qty, $price) = ($1, $2, $3, $4);
        push @line_items, {
            sku => $sku,
            name => $name,
            quantity => $qty,
            price => $price,
            source => 'email_parsing',
        };
    }
    
    # Pattern 4: "ITEM: NAME - QTY: QUANTITY - PRICE: $PRICE"
    while ($text =~ /ITEM:\s*([^\n]+?)\s*-\s*QTY:\s*(\d+(?:\.\d+)?)\s*-\s*PRICE:\s*\$(\d+(?:\.\d+)?)/gi) {
        my ($name, $qty, $price) = ($1, $2, $3);
        push @line_items, {
            sku => '',
            name => $name,
            quantity => $qty,
            price => $price,
            source => 'email_parsing',
        };
    }
    
    return @line_items;
}

# Determine item category based on item name
sub _determine_item_category {
    my ($self, $name) = @_;
    
    $name = lc($name);
    
    if ($name =~ /filament|3d|printer|equipment|hardware|tool/) {
        return 'Equipment';
    }
    
    if ($name =~ /part|component|piece/) {
        return 'Hardware';
    }
    
    if ($name =~ /material|supply|consumable/) {
        return 'Supply';
    }
    
    if ($name =~ /data|information|document|file/) {
        return 'Digital';
    }
    
    return 'General';
}

# Enhanced draft_supplier_invoices with sitename-based email routing
# This configuration allows each sitename to define which emails to monitor
# and which supplier accounts are attached to those addresses.
sub draft_supplier_invoices {
    my ($self, $c, %args) = @_;
    require Comserv::Util::Inventory::MailInvoiceStock;
    return Comserv::Util::Inventory::MailInvoiceStock->new->apply($c, %args, classifier => $self);
}


1;