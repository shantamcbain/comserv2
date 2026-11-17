package Comserv::Util::Inventory::PhotoRead;

# One photo / barcode reader for items and supplier invoices. The web pages and
# the Android app call the SAME subs through /api/app/photo/* (only the view
# differs; Shanta's rule, 2026-11-16).
#
#   queue      request: store the photo + a JSON record (status=reading).
#   finish     background worker: VisionRead -> raw_text + parsed lines
#              (status=ready, or failed keeping whatever raw_text it got).
#   reparse    request: re-parse the (edited) raw_text with a text-only AI call,
#              falling back to parse_text. No vision call.
#   view       request: lines matched against inventory, totals check, supplier
#              match / candidates / proposal. Nothing is written.
#   confirm    request, after a person checked every line: create the chosen
#              supplier and items (InvoiceCreate::_auto_create_supplier and
#              ::_create_chat_item, same as chat entry), a DRAFT invoice through
#              MailInvoiceStock::draft_invoice, attach the photo to an item
#              (Comserv::Util::ItemImage->save). Never receives stock, never GL.
#   rerun / delete_photo / list_reads   photo retention (debug backup only).
#   scan / scan_apply   barcode or description -> item -> receive | count | use |
#              move through Comserv::Util::Inventory::StockTxn. Stores no picture.
#
# Records live in <app root>/data/photo_reads/<sitename>/<read_id>.json beside
# the photo. No table. The site always comes from the caller's session gate.

use strict;
use warnings;
use JSON ();
use File::Path qw(make_path);
use File::Copy ();
use Fcntl qw(:flock);
use Digest::SHA qw(sha1_hex);
use Comserv::Util::Logging;
use Comserv::Util::AppTime;
use Comserv::Util::VisionRead;
use Comserv::Util::Inventory::MailInvoiceStock;

our $VERSION = '1.10';

my $DIR = 'data/photo_reads';    # relative to the app root; gitignored
my %MODES = (items => 1, invoice => 1);
my $MAX_BYTES = 20 * 1024 * 1024;
my @SCAN_ACTIONS = qw(receive count use move);

sub new {
    my ($class, %args) = @_;
    my $self = {
        root    => $args{root} || '.',
        logging => $args{logging} || Comserv::Util::Logging->instance,
        vision  => $args{vision},
        grok    => $args{grok},
        stock   => $args{stock} || Comserv::Util::Inventory::MailInvoiceStock->new,
        brain   => $args{brain},
        text_ai => $args{text_ai},     # coderef ($c, $system, $user) -> text; tests inject it
    };
    return bless $self, $class;
}

sub vision {
    my ($self) = @_;
    $self->{vision} ||= Comserv::Util::VisionRead->new(
        num_predict    => 3000,
        timeout        => 600,
        tmp_prefix     => 'photo_read',
        log_tag        => 'PhotoRead',
        system_prompt  => 'You read photos of products and supplier invoices and reply with JSON only.',
        grok_in_worker => 1,
        ($self->{grok} ? (grok => $self->{grok}) : ()),
    );
    return $self->{vision};
}

sub brain {
    my ($self) = @_;
    unless ($self->{brain}) {
        require Comserv::Model::AI2::InvoiceCreate;
        $self->{brain} = Comserv::Model::AI2::InvoiceCreate->new;
    }
    return $self->{brain};
}

sub _log {
    my ($self, $c, $level, $msg) = @_;
    eval { $self->{logging}->log_with_details($c, $level, __FILE__, __LINE__, 'PhotoRead', $msg) };
    return;
}

sub _now { Comserv::Util::AppTime->now_utc . '' }
sub _fail { my ($st, $code, $msg) = @_; return { ok => 0, status => $st, code => $code, error => $msg } }

# ---------------------------------------------------------------- storage

sub clean_site {
    my ($self, $site) = @_;
    return '' unless defined $site;
    $site =~ s/[^A-Za-z0-9._-]//g;
    $site =~ s/^\.+//;
    return $site;
}

sub valid_id { my ($self, $id) = @_; return (defined $id && $id =~ /^[a-f0-9]{24}$/) ? 1 : 0 }

sub _dir  { my ($self, $site) = @_; return $self->{root} . '/' . $DIR . '/' . $self->clean_site($site) }
sub _file { my ($self, $site, $id) = @_; return $self->_dir($site) . "/$id.json" }

sub _new_id {
    my ($self) = @_;
    my $rand = '';
    if (open my $fh, '<:raw', '/dev/urandom') { read($fh, $rand, 16); close $fh }
    return substr(sha1_hex($rand . time . $$ . rand()), 0, 24);
}

sub _load {
    my ($self, $site, $id) = @_;
    return undef unless $self->valid_id($id) && length $self->clean_site($site);
    my $f = $self->_file($site, $id);
    return undef unless -f $f;
    open my $fh, '<:raw', $f or return undef;
    local $/;
    my $raw = <$fh>;
    close $fh;
    my $d = eval { JSON->new->utf8->decode($raw) };
    return ref $d eq 'HASH' ? $d : undef;
}

sub _save {
    my ($self, $site, $id, $data) = @_;
    my $dir = $self->_dir($site);
    eval { make_path($dir) unless -d $dir };
    $data->{updated_at} = $self->_now;
    my $f   = $self->_file($site, $id);
    my $tmp = "$f.$$.tmp";
    open my $fh, '>:raw', $tmp or return 0;
    print {$fh} JSON->new->utf8->canonical->encode($data);
    close $fh or return 0;
    return rename($tmp, $f) ? 1 : 0;
}

sub _lock {
    my ($self, $site, $id) = @_;
    open my $lock, '>', $self->_file($site, $id) . '.lock' or return undef;
    flock($lock, LOCK_EX) or return undef;
    return $lock;
}

# Owner, or an admin acting from the photo_reads list.
sub _owned {
    my ($self, $rec, %a) = @_;
    return 0 unless $rec;
    return 0 unless lc($rec->{sitename} // '') eq lc($self->clean_site($a{sitename}));
    return 1 if $a{is_admin};
    return 0 unless ($rec->{user_id} // '') eq (defined $a{user_id} ? "$a{user_id}" : '');
    return 1;
}

sub _drop_photo {
    my ($self, $rec) = @_;
    unlink $rec->{photo} if $rec->{photo} && -f $rec->{photo};
    $rec->{photo} = undef;
    $rec->{photo_deleted} = 1;
    return;
}

# ---------------------------------------------------------------- queue

# queue(sitename, user_id, username, mode, image_path, mime, location_id)
sub queue {
    my ($self, $c, %a) = @_;
    my $site = $self->clean_site($a{sitename});
    return _fail(400, 'unknown_site', 'No site for this read.') unless length $site;
    my $mode = lc($a{mode} // '');
    return _fail(400, 'bad_mode', "mode must be 'items' or 'invoice'") unless $MODES{$mode};
    my $src = $a{image_path};
    return _fail(400, 'no_photo', 'No photo supplied.') unless $src && -f $src && -s $src;
    return _fail(413, 'photo_too_large', 'Photo is larger than 20 MB.') if -s $src > $MAX_BYTES;

    my $mime = lc($a{mime} || 'image/jpeg');
    return _fail(415, 'not_an_image', 'Only image uploads can be read.') unless $mime =~ m{^image/[\w.+-]+$};
    my ($ext) = $mime =~ m{^image/(jpe?g|png|webp|gif|heic)$};
    $ext = 'jpg' if !$ext || $ext eq 'jpeg';

    my $id  = $self->_new_id;
    my $dir = $self->_dir($site);
    eval { make_path($dir) unless -d $dir };
    my $photo = "$dir/$id.$ext";
    unless (eval { File::Copy::copy($src, $photo) } && -s $photo) {
        $self->_log($c, 'error', "could not store photo in $dir: " . ($@ || $!));
        return _fail(500, 'store_failed', 'Could not store the photo for reading.');
    }
    my $loc = $a{location_id};
    $loc = undef unless defined $loc && $loc =~ /^\d+$/;
    my $rec = {
        read_id     => $id,
        mode        => $mode,
        sitename    => $site,
        user_id     => (defined $a{user_id} ? "$a{user_id}" : ''),
        username    => $a{username} // '',
        location_id => $loc,
        photo       => $photo,
        mime        => $mime,
        status      => 'reading',
        engine      => undef,
        error       => undef,
        raw_text    => '',
        parsed      => undef,
        created_at  => $self->_now,
    };
    return _fail(500, 'store_failed', 'Could not save the read record.') unless $self->_save($site, $id, $rec);
    $self->_log($c, 'info', "photo read $id queued ($mode, $site)");
    return { ok => 1, read_id => $id, status => 'reading' };
}

# ---------------------------------------------------------------- prompts + parsing

sub _shape {
    my ($mode) = @_;
    return $mode eq 'invoice'
        ? '{"raw_text":"every printed line of the document, top to bottom",'
          . '"supplier":"seller name","supplier_contact":{"phone":"","email":"","address":"","website":""},'
          . '"invoice_number":"","date":"YYYY-MM-DD","subtotal":0.00,"tax":0.00,"shipping":0.00,"total":0.00,'
          . '"lines":[{"name":"product description","sku":"item code if printed, else empty","qty":1,"unit_price":0.00}]}'
        : '{"raw_text":"all label / packaging text you can read",'
          . '"lines":[{"name":"short product name","sku_or_label_text":"code or label text, else empty","qty":1}]}';
}

sub prompt_for {
    my ($self, $mode) = @_;
    my $shape = _shape($mode);
    if ($mode eq 'invoice') {
        return <<"END";
This photo shows a supplier invoice, receipt or packing slip.
First transcribe ALL printed text into raw_text exactly as written (keep line breaks as \\n).
Then read every product line. Do not invent lines; totals, tax, shipping and payment lines are NOT product lines.
Copy the subtotal, tax (GST/HST/PST together), shipping and grand total when printed, else null.

Reply with JSON only, exactly this shape:
$shape
Use numbers for qty, unit_price and the totals. Empty string when a text value is not printed. No prose outside the JSON.
END
    }
    return <<"END";
This photo shows physical products (on a shelf, in a box, or on a table).
First transcribe all label text you can read into raw_text.
Then list each DISTINCT product you can see and how many of it are visible.

Reply with JSON only, exactly this shape:
$shape
Count only what you can see; never guess. No prose outside the JSON.
END
}

sub _str { my $v = shift; return '' unless defined $v && !ref $v; $v =~ s/^\s+|\s+$//g; return $v }
sub _num {
    my $v = shift;
    return undef unless defined $v && !ref $v;
    $v =~ s/[\$,\s]//g;
    return ($v =~ /^-?\d+(?:\.\d+)?$/) ? $v + 0 : undef;
}
sub _pos { my $n = _num(shift); return (defined $n && $n >= 0) ? $n : undef }

# Model text (JSON preferred) -> parsed hash, or undef.
#   { raw_text, supplier, supplier_contact{phone,email,address,website}, invoice_number,
#     date, subtotal, tax, shipping, total, lines => [ {name, sku, qty, unit_price} ] }
sub parse_text {
    my ($self, $mode, $text) = @_;
    return undef unless defined $text && length $text;
    my $json;
    if ($text =~ /(\{.*\})/s) { $json = eval { JSON->new->utf8(0)->decode($1) } }
    return $self->parse_plain($mode, $text) unless ref $json eq 'HASH';
    my $raw = $json->{lines} || $json->{items} || [];
    $raw = [] unless ref $raw eq 'ARRAY';
    my @lines;
    for my $l (@$raw) {
        next unless ref $l eq 'HASH';
        my $name = _str($l->{name} // $l->{description});
        my $sku  = _str($l->{sku} // $l->{sku_or_label_text} // $l->{code});
        next unless length $name || length $sku;
        my $qty = _num($l->{qty} // $l->{quantity});
        $qty = 1 unless defined $qty && $qty > 0;
        my $price = _pos($l->{unit_price} // $l->{price});
        push @lines, {
            name       => substr($name, 0, 250),
            sku        => substr($sku, 0, 100),
            qty        => $qty + 0,
            unit_price => ($mode eq 'invoice' && defined $price) ? $price + 0 : undef,
        };
    }
    my $raw_text = _str($json->{raw_text});
    unless (@lines) {
        # JSON with only a transcription: try the plain-text parser on it.
        my $p = length $raw_text ? $self->parse_plain($mode, $raw_text) : undef;
        return $p ? { %$p, raw_text => $raw_text } : undef;
    }
    my $out = { raw_text => $raw_text, lines => \@lines,
                supplier => '', supplier_contact => undef, invoice_number => '', date => '',
                subtotal => undef, tax => undef, shipping => undef, total => undef };
    if ($mode eq 'invoice') {
        my $date = _str($json->{date} // $json->{invoice_date});
        my $ct = ref $json->{supplier_contact} eq 'HASH' ? $json->{supplier_contact} : {};
        my %contact = map { $_ => substr(_str($ct->{$_}), 0, 255) } qw(phone email address website);
        $out->{supplier}         = _str($json->{supplier} // $json->{vendor});
        $out->{supplier_contact} = (grep { length } values %contact) ? \%contact : undef;
        $out->{invoice_number}   = substr(_str($json->{invoice_number} // $json->{number}), 0, 60);
        $out->{date}             = $date =~ /^\d{4}-\d{2}-\d{2}$/ ? $date : '';
        $out->{$_} = _pos($json->{$_}) for qw(subtotal tax shipping total);
        $out->{tax} //= _pos($json->{tax_amount});
        $out->{total} //= _pos($json->{total_amount});
        # Totals printed in raw_text but left out of the JSON.
        my $t = $self->_totals_from_text($raw_text);
        $out->{$_} //= $t->{$_} for keys %$t;
    }
    return $out;
}

# Plain transcription -> parsed hash, or undef. Heuristic, no AI:
#   "2 x Cashews 500g @ 7.50", "Cashews 500g   2   7.50   15.00", "3 Dates"
sub parse_plain {
    my ($self, $mode, $text) = @_;
    return undef unless defined $text && $text =~ /\S/;
    my @lines;
    my $skip = qr/\b(sub\s*-?\s*total|total|tax|gst|hst|pst|shipping|freight|delivery|balance|amount\s+due|paid|change|visa|mastercard|cash|invoice|date|page)\b/i;
    for my $row (split /\r?\n/, $text) {
        $row = _str($row);
        next unless length $row;
        next if $row =~ $skip;
        my ($qty, $name, $price);
        if ($row =~ /^(\d+(?:\.\d+)?)\s*(?:x|\*)\s*(.+?)(?:\s*@\s*\$?(\d+(?:\.\d+)?))?$/i) {
            ($qty, $name, $price) = ($1, $2, $3);
        } elsif ($row =~ /^(.*?[A-Za-z].*?)\s{2,}(\d+(?:\.\d+)?)\s+\$?(\d+\.\d{2})(?:\s+\$?\d+\.\d{2})?$/) {
            ($name, $qty, $price) = ($1, $2, $3);
        } elsif ($row =~ /^(\d+)\s+([A-Za-z].{2,})$/) {
            ($qty, $name) = ($1, $2);
        } else {
            next;
        }
        $name = _str($name);
        next unless $name =~ /[A-Za-z]{2}/;
        push @lines, { name => substr($name, 0, 250), sku => '', qty => $qty + 0,
                       unit_price => ($mode eq 'invoice' && defined $price) ? $price + 0 : undef };
    }
    return undef unless @lines;
    my $out = { raw_text => $text, lines => \@lines, supplier => '', supplier_contact => undef,
                invoice_number => '', date => '', subtotal => undef, tax => undef, shipping => undef, total => undef };
    if ($mode eq 'invoice') {
        my $t = $self->_totals_from_text($text);
        $out->{$_} = $t->{$_} for keys %$t;
        if ($text =~ /\b(?:invoice|inv)\s*(?:no\.?|number|#)\s*[:#]?\s*([A-Za-z0-9-]{1,40})/i) { $out->{invoice_number} = $1 }
        if ($text =~ /\b(\d{4}-\d{2}-\d{2})\b/) { $out->{date} = $1 }
    }
    return $out;
}

sub _totals_from_text {
    my ($self, $text) = @_;
    my %t;
    return \%t unless defined $text && length $text;
    my $money = qr/\$?\s*(\d{1,7}(?:,\d{3})*\.\d{2})/;
    for my $row (split /\r?\n/, $text) {
        if    ($row =~ /sub\s*-?\s*total[^\d\$]*$money/i)              { $t{subtotal} //= _num($1) }
        elsif ($row =~ /\b(?:tax|gst|hst|pst)\b[^\d\$]*$money/i)       { $t{tax} = ($t{tax} // 0) + _num($1) }
        elsif ($row =~ /\b(?:shipping|freight|delivery)\b[^\d\$]*$money/i) { $t{shipping} //= _num($1) }
        elsif ($row =~ /\b(?:grand\s+)?total\b[^\d\$]*$money/i)        { $t{total} = _num($1) }
    }
    return \%t;
}

# ---------------------------------------------------------------- read (worker)

sub finish {
    my ($self, $c, $site, $id) = @_;
    my $rec = $self->_load($site, $id) or return { ok => 0, error => "read $id not found" };
    return { ok => 0, error => "read $id is $rec->{status}" }
        unless ($rec->{status} // '') eq 'reading' || ($rec->{status} // '') eq 'failed';
    unless ($rec->{photo} && -f $rec->{photo}) {
        $rec->{status} = 'failed';
        $rec->{error}  = 'The stored photo is no longer on disk.';
        $self->_save($site, $id, $rec);
        return { ok => 0, error => $rec->{error} };
    }
    my $r = $self->vision->read($c,
        image_path => $rec->{photo},
        mime       => $rec->{mime},
        prompt     => $self->prompt_for($rec->{mode}),
    );
    my $parsed = $r->{ok} ? $self->parse_text($rec->{mode}, $r->{text}) : undef;
    if ($parsed) {
        $rec->{status}   = 'ready';
        $rec->{error}    = undef;
        $rec->{parsed}   = $parsed;
        $rec->{raw_text} = length($parsed->{raw_text} // '') ? $parsed->{raw_text} : ($rec->{raw_text} // '');
    } else {
        $rec->{status} = 'failed';
        $rec->{error}  = $r->{ok} ? 'The model did not return readable lines. Edit the text and Re-parse.'
                                  : ($r->{error} || 'Vision failed');
        # Keep whatever text came back so the user can correct it and reparse.
        if ($r->{ok} && defined $r->{text}) {
            my $txt = $r->{text};
            my $j = ($txt =~ /(\{.*\})/s) ? eval { JSON->new->utf8(0)->decode($1) } : undef;
            $rec->{raw_text} = substr((ref $j eq 'HASH' && $j->{raw_text}) ? $j->{raw_text} : $txt, 0, 20000);
        }
    }
    $rec->{engine} = $r->{engine};
    $self->_save($site, $id, $rec);
    $self->_log($c, ($parsed ? 'info' : 'warn'), "photo read $id -> $rec->{status}"
        . ($parsed ? ' (' . scalar(@{ $parsed->{lines} }) . ' lines)' : ": $rec->{error}"));
    return { ok => ($parsed ? 1 : 0), status => $rec->{status}, engine => $r->{engine}, error => $rec->{error} };
}

sub worker_main {
    my ($class, $root, $site, $id) = @_;
    $| = 1;
    my $grok = eval { require Comserv::Model::Grok; Comserv::Model::Grok->new };
    warn "grok model unavailable, local vision only: $@\n" unless $grok;
    my $self = $class->new(root => $root, ($grok ? (grok => $grok) : ()));
    my $res = $self->finish(undef, $site, $id);
    print "photo read $id: " . ($res->{ok} ? "ready via $res->{engine}" : 'failed: ' . ($res->{error} || '?')) . "\n";
    return $res->{ok} ? 0 : 1;
}

# Same detach rules as Controller::Inventory::_spawn_count_worker.
sub spawn_worker {
    my ($self, $c, $site, $id) = @_;
    return if $self->{no_spawn};
    return unless $self->valid_id($id);
    $site = $self->clean_site($site);
    my $lib = eval { $c->path_to('lib')->stringify } || ($self->{root} . '/lib');
    my $logdir = eval { $c->path_to('logs')->stringify } || ($self->{root} . '/logs');
    mkdir $logdir unless -d $logdir;
    my $log = "$logdir/photo_read_worker.log";
    my $pid = fork;
    unless (defined $pid) {
        $self->_log($c, 'error', "fork failed for photo read $id: $!");
        return;
    }
    if (!$pid) {
        require POSIX;
        eval {
            POSIX::setsid();
            open STDIN,  '<',  '/dev/null';
            open STDOUT, '>>', $log;
            open STDERR, '>>', $log;
            POSIX::close($_) for 3 .. 1023;
        };
        exec($^X, "-I$lib", '-MComserv::Util::Inventory::PhotoRead', '-e',
             'exit(Comserv::Util::Inventory::PhotoRead->worker_main(@ARGV))',
             $self->{root}, $site, $id)
            or POSIX::_exit(1);
    }
    $self->_log($c, 'info', "spawned photo read worker pid $pid for $id");
    return $pid;
}

# ---------------------------------------------------------------- reparse (text only)

# The text-only AI call that works inside a request: $c->model('Grok')->chat,
# the same text path Chat-with-AI uses. undef when unavailable.
sub _text_ai {
    my ($self, $c, $system, $user) = @_;
    return $self->{text_ai}->($c, $system, $user) if ref $self->{text_ai} eq 'CODE';
    return undef unless $c;
    my $grok = eval { $c->model('Grok') } or return undef;
    my $text = eval { $grok->chat(messages => [
        { role => 'system', content => $system },
        { role => 'user',   content => $user },
    ]) };
    return $text;
}

# reparse($c, sitename, user_id, read_id, raw_text) -> { ok, read_id, status, engine }
sub reparse {
    my ($self, $c, %a) = @_;
    my $site = $self->clean_site($a{sitename});
    return _fail(404, 'not_found', 'Photo read not found.')
        unless $self->valid_id($a{read_id}) && length $site && -f $self->_file($site, $a{read_id});
    my $lock = $self->_lock($site, $a{read_id}) or return _fail(500, 'lock_failed', 'Could not lock the read.');
    my $rec = $self->_load($site, $a{read_id});
    return _fail(404, 'not_found', 'Photo read not found.') unless $self->_owned($rec, %a, sitename => $site);
    return _fail(409, 'already_confirmed', 'This photo read was already confirmed.') if $rec->{status} eq 'confirmed';
    return _fail(409, 'not_ready', 'The photo is still being read.') if $rec->{status} eq 'reading';
    my $text = defined $a{raw_text} ? "$a{raw_text}" : ($rec->{raw_text} // '');
    $text =~ s/^\s+|\s+$//g;
    return _fail(400, 'no_text', 'Type or paste the text first.') unless length $text;
    $text = substr($text, 0, 20000);

    my $mode = $rec->{mode};
    my $sys = 'You turn the text of a ' . ($mode eq 'invoice' ? 'supplier invoice' : 'product photo')
            . ' into JSON. Reply with JSON only.';
    my $user = "Text:\n$text\n\nReply with JSON only, exactly this shape (raw_text may be empty):\n" . _shape($mode);
    my $ai = eval { $self->_text_ai($c, $sys, $user) };
    my ($parsed, $engine);
    if (defined $ai && length $ai) {
        $parsed = $self->parse_text($mode, $ai);
        $engine = 'text:ai' if $parsed;
    }
    unless ($parsed) {
        $parsed = $self->parse_text($mode, $text);
        $engine = 'text:parser' if $parsed;
    }
    $rec->{raw_text} = $text;
    unless ($parsed) {
        $self->_save($site, $rec->{read_id}, $rec);
        return _fail(422, 'no_lines', 'No product lines could be read from that text.');
    }
    $parsed->{raw_text} = $text;
    $rec->{parsed} = $parsed;
    $rec->{status} = 'ready';
    $rec->{error}  = undef;
    $rec->{engine} = $engine;
    $self->_save($site, $rec->{read_id}, $rec);
    close $lock;
    return { ok => 1, read_id => $rec->{read_id}, status => 'ready', engine => $engine };
}

# ---------------------------------------------------------------- view

sub view {
    my ($self, $c, $schema, %a) = @_;
    my $rec = $self->_load($a{sitename}, $a{read_id});
    return _fail(404, 'not_found', 'Photo read not found.') unless $self->_owned($rec, %a);
    return { ok => 1, read => $self->_present($c, $schema, $rec) };
}

sub invoice_totals {
    my ($self, $p) = @_;
    my $sum = 0;
    for my $l (@{ $p->{lines} || [] }) { $sum += ($l->{qty} || 0) * ($l->{unit_price} || 0) }
    $sum = 0 + sprintf('%.2f', $sum);
    my ($sub, $tax, $ship, $tot) = map { $p->{$_} } qw(subtotal tax shipping total);
    my $mismatch = 0;
    if (defined $sub) {
        $mismatch = abs($sum - $sub) > 0.02 ? 1 : 0;
    }
    if (!$mismatch && defined $tot) {
        $mismatch = abs($sum + ($tax || 0) + ($ship || 0) - $tot) > 0.02 ? 1 : 0;
    }
    return { subtotal => $sub, tax => $tax, shipping => $ship, total => $tot,
             lines_sum => $sum, mismatch => $mismatch };
}

sub _present {
    my ($self, $c, $schema, $rec) = @_;
    my $site = $rec->{sitename};
    my $p    = $rec->{parsed} || {};
    my $inv  = $rec->{mode} eq 'invoice';
    my $has  = $rec->{status} ne 'reading' && $rec->{parsed};
    my $supplier;
    if ($inv && $has) {
        my $name = $p->{supplier} // '';
        my $look = $schema ? $self->supplier_lookup($c, $schema, $site, $name) : { match_id => undef, candidates => [] };
        my $ct = $p->{supplier_contact} || {};
        $supplier = {
            name       => $name,
            match_id   => $look->{match_id},
            candidates => $look->{candidates},
            proposed   => $look->{match_id} ? undef : {
                name => $name, phone => $ct->{phone} // '', email => $ct->{email} // '',
                address => $ct->{address} // '', website => $ct->{website} // '' },
        };
    }
    my @lines;
    my $i = 0;
    for my $l (@{ $p->{lines} || [] }) {
        my $m = $schema ? $self->match_line($schema, $site, ($supplier ? $supplier->{match_id} : undef), $l) : undef;
        push @lines, {
            index        => $i++,
            name         => $l->{name},
            sku          => $l->{sku},
            qty          => $l->{qty},
            unit_price   => $l->{unit_price},
            match        => $m ? { item_id => 0 + $m->id, sku => $m->sku, name => $m->name } : undef,
            proposed_sku => $m ? undef : { name => $l->{name} || $l->{sku}, sku => ($l->{sku} // ''),
                                          supplier_sku => ($inv ? ($l->{sku} // '') : '') },
        };
    }
    my $invoice;
    if ($inv && $has) {
        $invoice = { number => $p->{invoice_number} // '', date => $p->{date} // '', %{ $self->invoice_totals($p) } };
    }
    return {
        read_id   => $rec->{read_id},
        mode      => $rec->{mode},
        sitename  => $site,
        status    => $rec->{status},
        engine    => $rec->{engine},
        raw_text  => $rec->{raw_text} // '',
        has_photo => ($rec->{photo} && -f $rec->{photo}) ? 1 : 0,
        supplier  => $supplier,
        invoice   => $invoice,
        lines     => \@lines,
        error     => $rec->{error},
        ($rec->{result} ? (result => $rec->{result}) : ()),
    };
}

# Supplier match + top-5 candidates through InvoiceCreate (match_supplier /
# list_suppliers / rank_parties, including its CSC paying-entity fallback).
sub supplier_lookup {
    my ($self, $c, $schema, $site, $name) = @_;
    my $out = { match_id => undef, candidates => [] };
    my $b = $self->brain;
    if ($c && defined $name && $name =~ /\S/) {
        my $m = eval { $b->match_supplier($c, sitename => $site, party => $name) };
        if (ref $m eq 'HASH') {
            $out->{match_id} = 0 + $m->{supplier}{id} if ($m->{status} // '') eq 'exact' && $m->{supplier};
            $out->{candidates} = [ map { { id => 0 + $_->{id}, name => $_->{name}, score => $_->{score} } }
                                   grep { ref $_ eq 'HASH' } @{ $m->{candidates} || [] } ];
        }
    }
    unless ($out->{match_id} || !$schema || !defined $name || $name !~ /\S/) {
        my $row = eval { $schema->resultset('Accounting::InventorySupplier')->search(
            { sitename => $site, name => $name }, { rows => 1 })->first };
        $out->{match_id} = 0 + $row->id if $row;
    }
    unless (@{ $out->{candidates} }) {
        my $pool = $c ? (eval { $b->list_suppliers($c, $site) } || []) : [];
        my $ranked = (defined $name && $name =~ /\S/) ? $b->rank_parties($name, $pool) : [];
        $ranked = [ map { { %$_, score => 0 } } @$pool ] unless @$ranked;
        $out->{candidates} = [ map { { id => 0 + $_->{id}, name => $_->{name}, score => $_->{score} } } @$ranked ];
    }
    splice @{ $out->{candidates} }, 5 if @{ $out->{candidates} } > 5;
    return $out;
}

sub match_supplier {
    my ($self, $c, $schema, $site, $name) = @_;
    return $self->supplier_lookup($c, $schema, $site, $name)->{match_id};
}

# SKU / supplier SKU / exact name via MailInvoiceStock::_match_item, then a
# case-insensitive name match, then a LIKE match accepted only when unique.
sub match_line {
    my ($self, $schema, $site, $supplier_id, $line) = @_;
    my $item = eval {
        $self->{stock}->_match_item($schema, $site, $supplier_id, { sku => $line->{sku}, name => $line->{name} });
    };
    return $item if $item;
    my $name = _str($line->{name});
    return undef unless length($name) >= 3;
    my $rs = eval { $schema->resultset('Accounting::InventoryItem') } or return undef;
    $item = eval {
        $rs->search({ sitename => $site, -and => [ \[ 'LOWER(me.name) = ?', lc $name ] ] }, { rows => 1 })->first;
    };
    return $item if $item;
    my @hits = $self->name_candidates($schema, $site, $name, 2);
    return @hits == 1 ? $hits[0] : undef;
}

sub name_candidates {
    my ($self, $schema, $site, $name, $rows) = @_;
    $name = _str($name);
    return () unless length($name) >= 3;
    (my $esc = lc $name) =~ s/([%_\\])/\\$1/g;
    return eval {
        $schema->resultset('Accounting::InventoryItem')->search(
            { sitename => $site, -and => [ \[ 'LOWER(me.name) LIKE ?', "%$esc%" ] ] },
            { rows => ($rows || 5), order_by => 'me.id' })->all;
    };
}

# ---------------------------------------------------------------- shared create helpers

# Same supplier create path as chat invoice entry (with its web-lookup enrich);
# then the contact details read off the invoice fill only blank fields.
sub create_supplier {
    my ($self, $c, $schema, $site, $sc, $user) = @_;
    return undef unless ref $sc eq 'HASH' && _str($sc->{name}) =~ /\S{2}/;
    my $made = $self->brain->_auto_create_supplier($c, $schema, {
        name => _str($sc->{name}), sitename => $site, user => $user,
        notes => 'Created from photo/scan confirm.',
    });
    return undef unless $made && $made->{id};
    my $row = eval { $schema->resultset('Accounting::InventorySupplier')->find($made->{id}) };
    if ($row) {
        my %fill;
        for my $f (qw(phone email address website)) {
            my $v = substr(_str($sc->{$f}), 0, 255);
            $fill{$f} = $v if length $v && !(defined $row->$f && $row->$f =~ /\S/);
        }
        eval { $row->update(\%fill) } if %fill;
    }
    return 0 + $made->{id};
}

# Same item create path as the photo confirm and chat entry.
sub create_item {
    my ($self, $c, $schema, $site, %a) = @_;
    my $made = $self->brain->_create_chat_item($c, $schema, {
        name         => $a{name},
        sku          => $a{sku},
        sitename     => $site,
        supplier_id  => $a{supplier_id},
        supplier_sku => $a{supplier_sku},
        unit_cost    => $a{unit_cost},
        user         => $a{user},
        notes        => $a{notes},
    });
    return undef unless $made && $made->{id};
    if (defined $a{barcode} && $a{barcode} =~ /\S/) {
        my $row = $schema->resultset('Accounting::InventoryItem')->find($made->{id});
        eval { $row->update({ barcode => substr(_str($a{barcode}), 0, 100) }) }
            if $row && !(defined $row->barcode && $row->barcode =~ /\S/);
    }
    return 0 + $made->{id};
}

# Upload-shaped wrapper so a stored read photo goes through ItemImage->save
# exactly like a phone upload (size, type sniff, filename, image_path update).
{
    package Comserv::Util::Inventory::PhotoRead::FileUpload;
    sub new      { my ($c, %a) = @_; bless {%a}, $c }
    sub tempname { $_[0]{tempname} }
    sub filename { $_[0]{filename} }
    sub size     { -s $_[0]{tempname} }
}

sub attach_photo {
    my ($self, $c, $rec, $item_id) = @_;
    return { ok => 0, error => 'The photo was already deleted.' } unless $rec->{photo} && -f $rec->{photo};
    # Shrink big phone photos (VisionRead::_downscale: ffmpeg to 1024 px, jpg).
    my ($path, $mime) = $self->vision->_downscale($rec->{photo}, $rec->{mime});
    my $ext = ($mime && $mime =~ m{png}) ? 'png' : ($mime && $mime =~ m{webp}) ? 'webp' : 'jpg';
    my $up = Comserv::Util::Inventory::PhotoRead::FileUpload->new(tempname => $path, filename => "photo.$ext");
    require Comserv::Util::ItemImage;
    my $r = Comserv::Util::ItemImage->save($c, $up, $rec->{sitename}, $item_id);
    unlink $path if $path ne $rec->{photo};
    $self->vision->{_tmp_path} = undef;
    return $r;
}

# ---------------------------------------------------------------- confirm

# confirm($c, $schema, sitename, user_id, username, read_id, lines => [...],
#         create_invoice, supplier_id?, supplier_create?{name,phone,email,address,website},
#         invoice_number?, invoice_date?, keep_photo?, attach_photo_index?)
sub confirm {
    my ($self, $c, $schema, %a) = @_;
    return _fail(403, 'forbidden', 'You may not create items or invoices.')
        if $c && !$self->brain->_can_write_invoice($c);
    my $site = $self->clean_site($a{sitename});
    return _fail(404, 'not_found', 'Photo read not found.')
        unless $self->valid_id($a{read_id}) && length $site && -f $self->_file($site, $a{read_id});
    my $lock = $self->_lock($site, $a{read_id}) or return _fail(500, 'lock_failed', 'Could not lock the read.');

    my $rec = $self->_load($site, $a{read_id});
    return _fail(404, 'not_found', 'Photo read not found.') unless $self->_owned($rec, %a, sitename => $site, is_admin => 0);
    return _fail(409, 'already_confirmed', 'This photo read was already confirmed.')
        if ($rec->{status} // '') eq 'confirmed';
    return _fail(409, 'not_ready', "This photo read is $rec->{status}, not ready.")
        unless ($rec->{status} // '') eq 'ready';

    my $parsed = $rec->{parsed}{lines} || [];
    my $want   = ref $a{lines} eq 'ARRAY' ? $a{lines} : [];
    return _fail(400, 'no_lines', 'No lines to confirm.') unless @$want;
    my $is_inv = $rec->{mode} eq 'invoice';
    my $make_invoice = ($is_inv && $a{create_invoice}) ? 1 : 0;
    my $attach_ix = $a{attach_photo_index};
    $attach_ix = undef unless defined $attach_ix && $attach_ix =~ /^\d+$/;

    my $supplier_id = $a{supplier_id};
    $supplier_id = undef unless defined $supplier_id && $supplier_id =~ /^\d+$/ && $supplier_id > 0;
    my $sup_create = (!$supplier_id && $is_inv && ref $a{supplier_create} eq 'HASH'
                      && _str($a{supplier_create}{name}) =~ /\S{2}/) ? $a{supplier_create} : undef;
    if ($is_inv && !$supplier_id && !$sup_create) {
        $supplier_id = $self->match_supplier($c, $schema, $site, $rec->{parsed}{supplier});
    }
    if ($supplier_id) {
        my $sup = eval { $schema->resultset('Accounting::InventorySupplier')->find($supplier_id) };
        return _fail(400, 'supplier_required', 'Supplier not found.') unless $sup;
    }
    if ($make_invoice && !$supplier_id && !$sup_create) {
        return _fail(400, 'supplier_required', 'Pick the supplier or send supplier_create.');
    }

    my $user = $a{username} || ($c ? eval { $c->session->{username} } : undef) || 'photo-read';
    my (@created, @matched, @skipped, @inv_lines, @attach, $invoice_id, $supplier_created);
    eval {
        $schema->txn_do(sub {
            if ($sup_create) {
                $supplier_id = $self->create_supplier($c, $schema, $site, $sup_create, $user)
                    or die { status => 400, code => 'supplier_create_failed', error => 'Could not create the supplier.' };
                $supplier_created = $supplier_id;
            }
            my %seen;
            for my $w (@$want) {
                next unless ref $w eq 'HASH';
                my $ix = $w->{index};
                die { status => 400, code => 'bad_line', error => 'Each line needs a valid index.' }
                    unless defined $ix && $ix =~ /^\d+$/ && $ix < @$parsed && !$seen{$ix}++;
                my $src = $parsed->[$ix];
                my $act = lc($w->{action} // '');
                my $qty   = _num($w->{qty});        $qty   = $src->{qty} unless defined $qty && $qty > 0;
                my $price = _pos($w->{unit_price}); $price = $src->{unit_price} unless defined $price;
                if ($act eq 'skip') { push @skipped, 0 + $ix; next }
                my $item_id;
                if ($act eq 'match') {
                    my $row = ($w->{item_id} && $w->{item_id} =~ /^\d+$/)
                        ? $schema->resultset('Accounting::InventoryItem')->find($w->{item_id}) : undef;
                    die { status => 400, code => 'bad_item', error => "Line $ix: item not found on this site." }
                        unless $row && lc($row->sitename || '') eq lc $site;
                    $item_id = 0 + $row->id;
                    push @matched, { index => 0 + $ix, item_id => $item_id, qty => $qty, unit_price => $price };
                }
                elsif ($act eq 'create') {
                    my $name = _str($w->{name}); $name = $src->{name} unless length $name;
                    my $sku  = defined $w->{sku} ? _str($w->{sku}) : $src->{sku};
                    $item_id = $self->create_item($c, $schema, $site,
                        name => $name, sku => $sku,
                        supplier_id  => ($is_inv ? $supplier_id : undef),
                        supplier_sku => ($is_inv ? $src->{sku} : undef),
                        unit_cost => $price, user => $user,
                        notes => "Added from photo read $rec->{read_id}.")
                        or die { status => 400, code => 'create_failed', error => "Line $ix: could not create '$name'." };
                    my $row = $schema->resultset('Accounting::InventoryItem')->find($item_id);
                    push @created, { index => 0 + $ix, item_id => $item_id,
                                     sku => ($row ? $row->sku : $sku), name => ($row ? $row->name : $name),
                                     qty => $qty, unit_price => $price };
                }
                else {
                    die { status => 400, code => 'bad_action', error => "Line $ix: action must be match, create or skip." };
                }
                push @attach, $item_id if !$is_inv && ($w->{attach_photo} || (defined $attach_ix && $attach_ix == $ix));
                push @inv_lines, { name => $src->{name} || $src->{sku}, sku => $src->{sku},
                                   quantity => $qty, price => $price, item_id => $item_id };
            }
            if ($make_invoice && @inv_lines) {
                my $no = _str($a{invoice_number} // $rec->{parsed}{invoice_number});
                $no = 'PHOTO-' . uc(substr($rec->{read_id}, 0, 10)) unless length $no;
                my $dup = $schema->resultset('Accounting::InventorySupplierInvoice')->search({
                    sitename => $site, supplier_id => $supplier_id, invoice_number => $no,
                })->count;
                die { status => 409, code => 'invoice_exists', error => "Invoice $no already exists for this supplier." } if $dup;
                my $date = _str($a{invoice_date} // $rec->{parsed}{date});
                $date = undef unless $date =~ /^\d{4}-\d{2}-\d{2}$/;
                my $sum = 0;
                $sum += ($_->{quantity} || 0) * ($_->{price} || 0) for @inv_lines;
                my $pp = $rec->{parsed};
                my $tax  = _pos($a{tax}      // $pp->{tax});
                my $ship = _pos($a{shipping} // $pp->{shipping});
                my $tot  = _pos($a{total}    // $pp->{total});
                $tot = $sum + ($tax || 0) + ($ship || 0) unless defined $tot;
                my $r = $self->{stock}->draft_invoice($c, $schema,
                    sitename        => $site,
                    supplier_id     => $supplier_id,
                    invoice_number  => $no,
                    invoice_date    => $date,
                    total_amount    => sprintf('%.2f', $tot),
                    tax_amount      => (defined $tax  ? sprintf('%.2f', $tax)  : undef),
                    shipping_amount => (defined $ship ? sprintf('%.2f', $ship) : undef),
                    notes           => "Draft from photo read $rec->{read_id}. Stock is received only on Accept. No GL post.",
                    created_by      => $user,
                    lines           => \@inv_lines,
                );
                die { status => 500, code => 'invoice_failed', error => $r->{error} } unless $r->{ok};
                $invoice_id = $r->{invoice_id};
            }
        });
    };
    if (my $e = $@) {
        $self->_log($c, 'error', "confirm $a{read_id} failed: " . (ref $e ? $e->{error} : $e));
        return ref $e eq 'HASH' ? { ok => 0, %$e } : _fail(500, 'confirm_failed', 'Confirm failed. Nothing was saved.');
    }

    my @attached;
    for my $iid (@attach) {
        my $r = $self->attach_photo($c, $rec, $iid);
        push @attached, $r->{ok} ? { item_id => $iid, image_path => $r->{image_path} }
                                 : { item_id => $iid, error => $r->{error} };
    }

    my $result = { invoice_id => $invoice_id, supplier_id => $supplier_id, supplier_created => $supplier_created,
                   created_items => \@created, matched => \@matched, skipped => \@skipped,
                   photos_attached => \@attached };
    # Retention: invoice photos are a debug backup only; item photos are done
    # once attached (or not wanted).
    my $keep = ($is_inv && $a{keep_photo}) ? 1 : 0;
    $self->_drop_photo($rec) unless $keep;
    $result->{photo_kept} = $keep;
    $rec->{status} = 'confirmed';
    $rec->{result} = $result;
    $rec->{confirmed_by} = $user;
    $rec->{confirmed_at} = $self->_now;
    $self->_save($site, $rec->{read_id}, $rec);
    close $lock;
    $self->_log($c, 'info', sprintf('photo read %s confirmed: %d created, %d matched, invoice %s',
        $rec->{read_id}, scalar @created, scalar @matched, $invoice_id // 'none'));
    return { ok => 1, %$result };
}

# ---------------------------------------------------------------- retention

# rerun($c, sitename, user_id, read_id, is_admin) -> { ok, read_id, status:'reading' }
sub rerun {
    my ($self, $c, %a) = @_;
    my $site = $self->clean_site($a{sitename});
    my $rec = $self->_load($site, $a{read_id});
    return _fail(404, 'not_found', 'Photo read not found.') unless $self->_owned($rec, %a, sitename => $site);
    return _fail(409, 'photo_deleted', 'The stored photo was deleted; it cannot be re-read.')
        unless $rec->{photo} && -f $rec->{photo};
    return _fail(409, 'already_confirmed', 'This photo read was already confirmed.') if $rec->{status} eq 'confirmed';
    return _fail(409, 'not_ready', 'The photo is still being read.') if $rec->{status} eq 'reading';
    $rec->{status} = 'reading';
    $rec->{error}  = undef;
    $self->_save($site, $rec->{read_id}, $rec);
    return { ok => 1, read_id => $rec->{read_id}, status => 'reading' };
}

sub delete_photo {
    my ($self, $c, %a) = @_;
    my $site = $self->clean_site($a{sitename});
    my $rec = $self->_load($site, $a{read_id});
    return _fail(404, 'not_found', 'Photo read not found.') unless $self->_owned($rec, %a, sitename => $site);
    $self->_drop_photo($rec);
    $self->_save($site, $rec->{read_id}, $rec);
    return { ok => 1, read_id => $rec->{read_id}, photo_deleted => 1 };
}

# Admin only. Every site. -> { ok, reads:[{read_id, sitename, user_id, username, mode, status,
#                                         has_photo, created_at, updated_at}] }
sub list_reads {
    my ($self, $c, %a) = @_;
    return _fail(403, 'forbidden', 'Admins only.') unless $a{is_admin};
    my @out;
    my $base = $self->{root} . '/' . $DIR;
    for my $f (glob("$base/*/*.json")) {
        my ($site, $id) = $f =~ m{/([^/]+)/([a-f0-9]{24})\.json$} or next;
        my $rec = $self->_load($site, $id) or next;
        next if $a{kept_only} && !($rec->{photo} && -f $rec->{photo});
        push @out, { read_id => $id, sitename => $rec->{sitename}, user_id => $rec->{user_id},
                     username => $rec->{username}, mode => $rec->{mode}, status => $rec->{status},
                     has_photo => ($rec->{photo} && -f $rec->{photo}) ? 1 : 0,
                     created_at => $rec->{created_at}, updated_at => $rec->{updated_at} };
    }
    @out = sort { ($b->{created_at} // '') cmp ($a->{created_at} // '') } @out;
    splice @out, 500 if @out > 500;
    return { ok => 1, reads => \@out };
}

# ---------------------------------------------------------------- barcode scan

sub _stock_for {
    my ($self, $schema, $item_id) = @_;
    my @rows = eval {
        $schema->resultset('Accounting::InventoryStockLevel')->search({ item_id => $item_id }, { order_by => 'location_id' })->all;
    };
    my @out;
    for my $s (@rows) {
        next unless $s->location_id;
        my $loc = eval { $schema->resultset('Accounting::InventoryLocation')->find($s->location_id) };
        push @out, { location_id => 0 + $s->location_id, location_name => ($loc ? $loc->name : ''),
                     qty => 0 + ($s->quantity_on_hand // 0) };
    }
    return \@out;
}

sub _item_out {
    my ($self, $schema, $item) = @_;
    return { item_id => 0 + $item->id, sku => $item->sku, name => $item->name,
             barcode => (eval { $item->barcode } // undef),
             image_url => (eval { $item->image_path } // undef),
             stock => $self->_stock_for($schema, $item->id) };
}

# scan($c, $schema, sitename, barcode?, description?, inv => Controller::Inventory)
sub scan {
    my ($self, $c, $schema, %a) = @_;
    my $site = $self->clean_site($a{sitename});
    my $bc   = _str($a{barcode});
    my $desc = _str($a{description});
    return _fail(400, 'nothing_to_scan', 'Send a barcode or a description.') unless length $bc || length $desc;
    my ($item, $by);
    if (length $bc && $a{inv}) {
        require Comserv::Util::InventoryBarcode;
        my $r = Comserv::Util::InventoryBarcode->by_barcode($c, $site, $a{inv}, $bc);
        if ($r && $r->{found} && $r->{item} && $r->{item}{id}) {
            $item = eval { $schema->resultset('Accounting::InventoryItem')->find($r->{item}{id}) };
            $by = 'barcode' if $item;
        }
    }
    my @cands;
    if (!$item && length $desc) {
        $item = $self->match_line($schema, $site, undef, { name => $desc, sku => '' });
        $by = 'description' if $item;
        @cands = $self->name_candidates($schema, $site, $desc, 5) unless $item;
    }
    return {
        ok           => 1,
        found        => $item ? 1 : 0,
        matched_by   => $by,
        item         => $item ? $self->_item_out($schema, $item) : undef,
        candidates   => [ map { { item_id => 0 + $_->id, sku => $_->sku, name => $_->name } } @cands ],
        proposed_sku => $item ? undef : { name => $desc, sku => '', barcode => $bc },
        actions      => [ @SCAN_ACTIONS ],
        locations    => $self->site_locations($schema, $site),
    };
}

sub site_locations {
    my ($self, $schema, $site) = @_;
    my @rows = eval {
        $schema->resultset('Accounting::InventoryLocation')->search(
            { sitename => $site, status => [ 'active', undef ] }, { order_by => 'name' })->all;
    };
    return [ map { { id => 0 + $_->id, name => $_->name } } @rows ];
}

sub _site_location {
    my ($self, $schema, $site, $id) = @_;
    return undef unless defined $id && $id =~ /^\d+$/;
    my $loc = eval { $schema->resultset('Accounting::InventoryLocation')->find($id) };
    return ($loc && lc($loc->sitename // '') eq lc $site) ? $loc : undef;
}

# scan_apply($c, $schema, sitename, username, user_id, item_id | create{name, sku, barcode, unit_cost},
#            action, qty, location_id, to_location_id, unit_cost, supplier_id)
# Writes through Comserv::Util::Inventory::StockTxn (same code as
# /Inventory/api/transaction). No GL post. No picture stored.
sub scan_apply {
    my ($self, $c, $schema, %a) = @_;
    my $site = $self->clean_site($a{sitename});
    my $act  = lc($a{action} // '');
    return _fail(400, 'bad_action', 'action must be receive, count, use or move.') unless grep { $_ eq $act } @SCAN_ACTIONS;
    my $qty = _num($a{qty});
    return _fail(400, 'bad_qty', 'qty must be a number.') unless defined $qty;
    return _fail(400, 'bad_qty', 'qty must be greater than 0.') if $act ne 'count' && $qty <= 0;
    return _fail(400, 'bad_qty', 'A count cannot be negative.') if $qty < 0;

    my $loc = $a{location_id} ? $self->_site_location($schema, $site, $a{location_id}) : undef;
    return _fail(400, 'bad_location', 'Location not found on this site.') if $a{location_id} && !$loc;
    if (!$loc && $act eq 'receive') { $loc = eval { $self->{stock}->_default_location($schema, $site) } }
    return _fail(400, 'location_required', 'Pick the storage location.') unless $loc;
    my $to;
    if ($act eq 'move') {
        $to = $self->_site_location($schema, $site, $a{to_location_id})
            or return _fail(400, 'bad_location', 'Pick the location to move to.');
        return _fail(400, 'bad_location', 'From and to are the same location.') if $to->id == $loc->id;
    }
    my $cr = ref $a{create} eq 'HASH' ? $a{create} : undef;
    return _fail(403, 'forbidden', 'You may not create items.')
        if $cr && $c && !$self->brain->_can_write_invoice($c);
    my $supplier_id = (defined $a{supplier_id} && $a{supplier_id} =~ /^\d+$/) ? $a{supplier_id} : undef;
    my $cost = _pos($a{unit_cost});
    my $user = $a{username} || 'scan';
    my $now  = Comserv::Util::AppTime->now_utc . '';
    my %base = (sitename => $site, username => $user, user_id => $a{user_id}, now => $now, no_gl => 1);

    my ($item_id, $created, @txns);
    eval {
        $schema->txn_do(sub {
            if ($cr) {
                $item_id = $self->create_item($c, $schema, $site,
                    name => _str($cr->{name}), sku => _str($cr->{sku}), barcode => $cr->{barcode},
                    unit_cost => (_pos($cr->{unit_cost}) // $cost), supplier_id => $supplier_id,
                    user => $user, notes => 'Added from a barcode scan.')
                    or die { status => 400, code => 'create_failed', error => 'Could not create the item.' };
                $created = 1;
            } else {
                my $row = ($a{item_id} && $a{item_id} =~ /^\d+$/)
                    ? $schema->resultset('Accounting::InventoryItem')->find($a{item_id}) : undef;
                die { status => 404, code => 'item_not_found', error => 'Item not found on this site.' }
                    unless $row && lc($row->sitename // '') eq lc $site;
                $item_id = 0 + $row->id;
            }
            require Comserv::Util::Inventory::StockTxn;
            my $post = sub { my ($id) = Comserv::Util::Inventory::StockTxn->post($schema, %base, item_id => $item_id, @_); push @txns, 0 + $id };
            if ($act eq 'receive') {
                $post->(type => 'receive', qty => $qty, location_id => $loc->id, unit_cost => $cost,
                        direction => 1, reference_number => 'SCAN-RECV',
                        notes => 'Scan receive' . ($supplier_id ? " (supplier #$supplier_id)" : ''));
            } elsif ($act eq 'use') {
                $post->(type => 'use', qty => $qty, location_id => $loc->id, direction => -1,
                        reference_number => 'SCAN-USE', notes => 'Scan use-up');
            } elsif ($act eq 'count') {
                my $sl = $schema->resultset('Accounting::InventoryStockLevel')->find(
                    { item_id => $item_id, location_id => $loc->id });
                my $old  = $sl ? 0 + ($sl->quantity_on_hand // 0) : 0;
                my $diff = $qty - $old;
                if ($diff != 0) {
                    $post->(type => 'count_adjust', qty => abs($diff), store_quantity => $diff,
                            direction => ($diff > 0 ? 1 : -1), location_id => $loc->id,
                            reference_number => 'SCAN-COUNT', notes => "Scan count: $old -> $qty");
                }
                my $sl2 = $schema->resultset('Accounting::InventoryStockLevel')->find(
                    { item_id => $item_id, location_id => $loc->id });
                eval { $sl2->update({ last_count_date => $now }) } if $sl2;
            } elsif ($act eq 'move') {
                $post->(type => 'transfer', qty => $qty, location_id => $loc->id, direction => -1,
                        reference_number => 'SCAN-MOVE', notes => 'Move to ' . $to->name);
                $post->(type => 'transfer', qty => $qty, location_id => $to->id, direction => 1,
                        reference_number => 'SCAN-MOVE', notes => 'Move from ' . $loc->name);
            }
        });
    };
    if (my $e = $@) {
        $self->_log($c, 'error', "scan_apply $act failed: " . (ref $e ? $e->{error} : $e));
        return ref $e eq 'HASH' ? { ok => 0, %$e } : _fail(500, 'apply_failed', 'Nothing was saved.');
    }
    my $item = $schema->resultset('Accounting::InventoryItem')->find($item_id);
    return { ok => 1, action => $act, item_id => $item_id, created => $created ? 1 : 0,
             transactions => \@txns, item => $self->_item_out($schema, $item) };
}

1;
