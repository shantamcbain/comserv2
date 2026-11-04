package Comserv::Util::CalendarFeed;

# Calendar phase 1 (Nov 2026): reminder offsets, read-only ICS feed with VALARM,
# feed-token handling and log redaction. Pure helpers, no Catalyst context needed
# except where a $schema is passed. All access decisions go through
# Comserv::Util::AccessCheck. See root/Documentation/CalendarFeed.md.

use strict;
use warnings;
use utf8;
use Encode qw(encode_utf8 decode_utf8);
use Digest::SHA qw(sha256_hex);
use MIME::Base64 qw(encode_base64);
use Comserv::Util::AccessCheck;

our $TOKEN_NAME     = 'calendar-feed';
our $SCOPE_MODULES  = 'calendar,todo';
our $SCOPE_ACTIONS  = 'read';
our $MAX_OFFSETS    = 5;
our $MAX_OFFSET_MIN = 4 * 7 * 24 * 60;     # 4 weeks
our $RATE_WINDOW    = 60;                  # seconds
our $RATE_MAX       = 20;                  # requests per token per window (per worker)
our $PAST_DAYS      = 30;
our $FUTURE_DAYS    = 365;

# ---------------------------------------------------------------- reminders ----

# Parse "-PT60M,-PT15M" (RFC 5545 DURATION, before the start). Returns
# (\@normalised, \@rejected). A missing leading '-' is accepted and added.
sub parse_offsets {
    my ($class, $str) = @_;
    my (@ok, @bad, %seen);
    for my $raw (split /[,\s]+/, ($str // '')) {
        next unless length $raw;
        my $v = uc $raw;
        $v = "-$v" if $v =~ /^P/;
        my $m = $class->offset_minutes($v);
        if (!defined $m || $m <= 0 || $m > $MAX_OFFSET_MIN) { push @bad, $raw; next }
        my $n = $class->minutes_to_duration($m);
        next if $seen{$n}++;
        push @ok, $n;
    }
    if (@ok > $MAX_OFFSETS) { push @bad, splice(@ok, $MAX_OFFSETS) }
    # largest offset first (earliest alarm first)
    @ok = sort { $class->offset_minutes($b) <=> $class->offset_minutes($a) } @ok;
    return (\@ok, \@bad);
}

sub offset_minutes {
    my ($class, $v) = @_;
    return undef unless defined $v
        && $v =~ /^-P(?:(\d+)W)?(?:(\d+)D)?(?:T(?=\d)(?:(\d+)H)?(?:(\d+)M)?)?$/
        && $v ne '-P';
    my ($w, $d, $h, $mi) = map { $_ // 0 } ($1, $2, $3, $4);
    return (($w * 7 + $d) * 24 + $h) * 60 + $mi;
}

sub minutes_to_duration {
    my ($class, $m) = @_;
    return "-P" . ($m / 1440) . "D" if $m % 1440 == 0;
    my $h = int($m / 60); my $mi = $m % 60;
    return '-PT' . ($h ? "${h}H" : '') . ($mi ? "${mi}M" : '');
}

sub offsets_human {
    my ($class, $list) = @_;
    return join ', ', map {
        my $m = $class->offset_minutes($_) // 0;
        $m % 1440 == 0 ? ($m / 1440) . ' day(s) before'
      : $m % 60   == 0 ? ($m / 60) . ' hour(s) before'
      :                  "$m min before"
    } @{ $list || [] };
}

# Reminders live in todo_reminders (Result TodoReminder) so the todo table and
# every existing todo query keep working before Schema Compare runs.
sub load_reminders {
    my ($class, $schema, @ids) = @_;
    my %out;
    @ids = grep { defined && /^\d+$/ } @ids or return \%out;
    eval {
        for my $r ($schema->resultset('TodoReminder')->search({ todo_record_id => { -in => \@ids } })->all) {
            my ($ok) = $class->parse_offsets($r->offsets);
            $out{ $r->todo_record_id } = $ok if @$ok;
        }
        1;
    };
    return \%out;
}

# Returns { ok => 1, offsets => [...], rejected => [...] } or { ok => 0, error }.
sub save_reminders {
    my ($class, $schema, $todo_id, $str, $now) = @_;
    return { ok => 0, error => 'bad todo id' } unless defined $todo_id && $todo_id =~ /^\d+$/;
    my ($ok, $bad) = $class->parse_offsets($str);
    my $res = eval {
        my $rs = $schema->resultset('TodoReminder');
        my $row = $rs->search({ todo_record_id => $todo_id })->single;
        if (!@$ok) { $row->delete if $row }
        elsif ($row) { $row->update({ offsets => join(',', @$ok), updated_at => $now }) }
        else { $rs->create({ todo_record_id => $todo_id, offsets => join(',', @$ok), updated_at => $now }) }
        1;
    };
    return { ok => 0, error => 'Reminders table not available yet (run Schema Compare)', rejected => $bad } unless $res;
    return { ok => 1, offsets => $ok, rejected => $bad };
}

# ------------------------------------------------------------------- tokens ----

sub new_token {
    require Crypt::URandom;
    my $b = Crypt::URandom::urandom(32);
    my $t = encode_base64($b, '');
    $t =~ tr{+/}{-_}; $t =~ s/=+$//;
    return $t;                                  # 43 url-safe chars, 256 bits
}

sub hash_token { return sha256_hex($_[1] // '') }

sub _ct_eq {
    my ($a, $b) = @_;
    return 0 unless defined $a && defined $b && length $a == length $b;
    my $r = 0; $r |= ord(substr($a, $_, 1)) ^ ord(substr($b, $_, 1)) for 0 .. length($a) - 1;
    return $r == 0 ? 1 : 0;
}

# Validate a feed token. Fails CLOSED. Returns { ok => 1, user_id, token_id, scope }
# or { ok => 0, code }. $now_dt: DateTime in UTC (Comserv::Util::AppTime->now_dt).
sub validate_token {
    my ($class, $schema, $plain, $now_dt) = @_;
    my $deny = sub { return { ok => 0, code => $_[0] } };
    return $deny->('format') unless defined $plain && $plain =~ /^[A-Za-z0-9_-]{43,128}$/;
    my $h = $class->hash_token($plain);
    my $row = eval { $schema->resultset('ApiToken')->search({ token_hash => $h }, { rows => 1 })->single };
    return $deny->('lookup') if $@;
    return $deny->('unknown') unless $row && _ct_eq($row->token_hash, $h);
    my $res = eval {
        return $deny->('kind')     unless ($row->token_name // '') eq $TOKEN_NAME;
        return $deny->('inactive') unless $row->is_active;
        return $deny->('revoked')  if $row->revoked_at;
        if (my $exp = $row->expires_at) {
            require Comserv::Util::AppTime;
            $exp = Comserv::Util::AppTime->parse_stored($exp) unless ref $exp;
            return $deny->('expiry') unless ref $exp && $now_dt;
            return $deny->('expired') if DateTime->compare($exp, $now_dt) <= 0;
        }
        my $scope = Comserv::Util::AccessCheck->token_scope($schema, $row->id);
        # Feed tokens MUST carry the calendar read own_only scope; unscoped = refused.
        return $deny->('scope') unless $scope && !$scope->{_scope_error}
            && $scope->{own_only}
            && _has($scope->{scope_modules}, 'calendar')
            && _has($scope->{scope_actions}, 'read')
            && !_has_other($scope->{scope_actions}, 'read');
        return { ok => 1, user_id => $row->user_id, token_id => $row->id, scope => $scope, row => $row };
    };
    return $res && ref $res ? $res : $deny->('error');
}

sub _has { my ($l, $v) = @_; return 0 unless defined $l; return scalar grep { lc($_) eq $v } split /\s*,\s*/, $l }
sub _has_other { my ($l, $v) = @_; return 1 unless defined $l; return scalar grep { lc($_) ne $v } split /\s*,\s*/, $l }

# ---------------------------------------------------------- rate limiting ----

my %RATE;
sub rate_ok {
    my ($class, $key, $now) = @_;
    $now //= time;
    my $b = $RATE{$key} ||= [];
    @$b = grep { $_ > $now - $RATE_WINDOW } @$b;
    return 0 if @$b >= $RATE_MAX;
    push @$b, $now;
    %RATE = map { $_ => $RATE{$_} } grep { @{ $RATE{$_} } } keys %RATE if keys %RATE > 5000;
    return 1;
}
sub _rate_reset { %RATE = () }

# ---------------------------------------------------------------- redaction ----

sub redact {
    my ($class, $s) = @_;
    return $s unless defined $s;
    $s =~ s{(\bcalendar/feed/)[^\s/?#"'<>]+}{$1\[REDACTED\]}g;
    $s =~ s{([?&](?:token|feed_token)=)[^&\s"'<>]+}{$1\[REDACTED\]}gi;
    return $s;
}

# ---------------------------------------------------------- public host ----

# Public domains must be HTTPS. LAN/.local/localhost may be plain http.
sub transport_ok {
    my ($class, %a) = @_;
    my $host = lc($a{host} // ''); $host =~ s/:\d+$//;
    return 1 if $a{secure};
    # X-Forwarded-Proto counts only from a trusted proxy (Comserv::Util::ClientIP list).
    if (lc($a{forwarded_proto} // '') eq 'https' && defined $a{remote}) {
        require Comserv::Util::ClientIP;
        return 1 if Comserv::Util::ClientIP->is_trusted_proxy($a{remote});
    }
    return 1 if $host eq 'localhost' || $host =~ /\.local$/ || $host =~ /^127\./ || $host eq '::1'
        || $host =~ /^192\.168\./ || $host =~ /^10\./ || $host !~ /\./;
    return 0;
}

# ---------------------------------------------------------------- ICS text ----

sub ics_escape {
    my ($class, $s) = @_;
    $s = '' unless defined $s;
    $s =~ s/\r\n?/\n/g;
    $s =~ s/\\/\\\\/g;
    $s =~ s/;/\\;/g;
    $s =~ s/,/\\,/g;
    $s =~ s/\n/\\n/g;
    $s =~ s/[\x00-\x08\x0B-\x1F\x7F]//g;
    return $s;
}

# Fold a content line at 75 octets (RFC 5545 3.1) without splitting UTF-8 chars.
sub ics_fold {
    my ($class, $line) = @_;
    my @out; my $cur = ''; my $limit = 75;
    for my $ch (split //, $line) {
        my $len = length encode_utf8($ch);
        if (length(encode_utf8($cur)) + $len > $limit) { push @out, $cur; $cur = ''; $limit = 74 }
        $cur .= $ch;
    }
    push @out, $cur;
    return join "\r\n ", @out;
}

# Strip private material from a todo description for the feed: internal-note
# sections, credential-looking lines, and links that are not app URLs.
sub public_description {
    my ($class, $text, $app_base) = @_;
    $text = '' unless defined $text;
    $text =~ s/^#+\s*(?:internal|admin|private)[^\n]*\n.*?(?=^#+\s|\z)//gims;
    $text = join "\n", grep { !/(?:password|passwd|secret|api[_ -]?key|token|bearer)\s*[:=]/i } split /\n/, $text;
    my $base = $app_base // '';
    $base =~ s{/+$}{};
    $text =~ s{\bhttps?://[^\s<>"']+}{ (length $base && index(lc $&, lc "$base/") == 0) || lc $& eq lc $base ? $& : '[link removed]' }ge;
    $text = substr($text, 0, 2000) . '...' if length $text > 2000;
    return $text;
}

sub _dt_utc { my ($s) = @_; $s =~ s/[-:]//g; $s =~ s/ /T/; return $s . 'Z' }

# events: [{ uid, summary, description, url, sitename, start_date, start_dt, end_dt, offsets }]
#   start_dt/end_dt 'YYYY-MM-DD HH:MM:SS' UTC; else all-day on start_date.
sub build_ics {
    my ($class, %a) = @_;
    my $stamp = _dt_utc($a{now} // '1970-01-01 00:00:00');
    my @L = ('BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Comserv//Calendar Feed 1.0//EN',
             'CALSCALE:GREGORIAN', 'METHOD:PUBLISH',
             'X-WR-CALNAME:' . $class->ics_escape($a{name} // 'Comserv'),
             'REFRESH-INTERVAL;VALUE=DURATION:PT30M', 'X-PUBLISHED-TTL:PT30M');
    for my $e (@{ $a{events} || [] }) {
        push @L, 'BEGIN:VEVENT', 'UID:' . $class->ics_escape($e->{uid}), "DTSTAMP:$stamp";
        if ($e->{start_dt}) {
            push @L, 'DTSTART:' . _dt_utc($e->{start_dt});
            push @L, 'DTEND:' . _dt_utc($e->{end_dt}) if $e->{end_dt};
        } else {
            (my $d = $e->{start_date}) =~ s/-//g;
            push @L, "DTSTART;VALUE=DATE:$d";
            if ($e->{end_date}) { (my $x = $e->{end_date}) =~ s/-//g; push @L, "DTEND;VALUE=DATE:$x" }
        }
        push @L, 'SUMMARY:' . $class->ics_escape($e->{summary});
        push @L, 'DESCRIPTION:' . $class->ics_escape($e->{description}) if defined $e->{description} && length $e->{description};
        push @L, 'URL:' . $e->{url} if $e->{url} && $e->{url} =~ m{^https?://[^\s"<>]+$};
        push @L, 'CATEGORIES:' . $class->ics_escape($e->{sitename}) if $e->{sitename};
        push @L, 'STATUS:' . ($e->{done} ? 'CANCELLED' : 'CONFIRMED');
        for my $o (@{ $e->{offsets} || [] }) {
            next unless defined $class->offset_minutes($o);
            push @L, 'BEGIN:VALARM', 'ACTION:DISPLAY', "TRIGGER:$o",
                     'DESCRIPTION:' . $class->ics_escape($e->{summary}), 'END:VALARM';
        }
        push @L, 'END:VEVENT';
    }
    push @L, 'END:VCALENDAR';
    return join('', map { $class->ics_fold($_) . "\r\n" } @L);
}

# ------------------------------------------------------------ feed content ----

# The owner's SiteNames from user_site_roles at request time ('none' grants nothing),
# narrowed by calendar.visible_sites when set, each checked with AccessCheck
# (todo read, own_only via the token scope).
sub feed_sites {
    my ($class, $schema, $user, $scope, $visible) = @_;
    my %names;
    eval {
        for my $r ($schema->resultset('UserSiteRole')->search({ user_id => $user->{user_id}, is_active => 1 })->all) {
            my $s = eval { $schema->resultset('Site')->find($r->site_id) } or next;
            my $n = $s->name // ''; $names{$n} = 1 if length $n;
        }
        1;
    } or return [];
    if ($visible && ref $visible eq 'ARRAY' && @$visible) {
        my %v = map { $_ => 1 } @$visible;
        %names = map { $_ => 1 } grep { $v{$_} } keys %names;
    }
    my @ok;
    for my $site (sort keys %names) {
        next if Comserv::Util::AccessCheck->is_no_rights_site($site);
        my $acc = Comserv::Util::AccessCheck->check($schema, user => $user, module => 'calendar',
            action => 'read', sitename => $site, token => $scope, legacy_roles => [qw(admin developer)]);
        my $acc2 = $acc->{ok} ? Comserv::Util::AccessCheck->check($schema, user => $user, module => 'todo',
            action => 'read', sitename => $site, token => $scope, legacy_roles => [qw(admin developer)]) : $acc;
        push @ok, $site if $acc->{ok} && $acc2->{ok};
    }
    return \@ok;
}

sub feed_events {
    my ($class, $schema, %a) = @_;
    my $user = $a{user}; my $sites = $a{sites} || [];
    return [] unless @$sites;
    my $own = Comserv::Util::AccessCheck->own_where('todo', $user);
    my @todos = eval { $schema->resultset('Todo')->search(
        { -and => [ $own, { sitename => { -in => $sites } },
                    { -or => [ { start_date => { '>=', $a{from} } }, { due_date => { '>=', $a{from} } } ] },
                    { start_date => { '<=', $a{to} } },
                    { status => { -not_in => [qw(3 4 DONE CANCELLED)] } } ] },
        { order_by => ['start_date', 'record_id'], rows => 1000 })->all };
    my $rem = $class->load_reminders($schema, map { $_->record_id } @todos);
    my $base = $a{app_base} // ''; $base =~ s{/+$}{};
    my @ev;
    for my $t (@todos) {
        # Defence in depth: never emit a record the user does not own.
        next unless Comserv::Util::AccessCheck->owns('todo', $t, $user);
        my $id = $t->record_id;
        my $sd = $t->get_column('start_date') || $t->get_column('due_date') or next;
        $sd = substr($sd, 0, 10);
        my ($ss, $se) = (eval { $t->get_column('scheduled_start') }, eval { $t->get_column('scheduled_end') });
        my $url = length $base ? "$base/todo/details?record_id=$id" : undef;
        my $desc = $class->public_description($t->get_column('description'), $base);
        $desc .= ($desc ? "\n\n" : '') . "Todo #$id: $url" if $url;
        my %e = (uid => "todo-$id\@comserv", summary => $t->get_column('subject'), description => $desc,
                 url => $url, sitename => $t->get_column('sitename'), offsets => $rem->{$id} || []);
        if ($ss && $ss =~ /^\d{4}-\d\d-\d\d[ T]\d\d:\d\d(:\d\d)?/ && substr($ss, 0, 10) ne '0000-00-00') {
            $ss =~ s/T/ /; $ss .= ':00' if length $ss == 16;
            $e{start_dt} = substr($ss, 0, 19);
            if ($se && $se =~ /^\d{4}-\d\d-\d\d[ T]\d\d:\d\d/ && $se gt $ss) { $se =~ s/T/ /; $se .= ':00' if length $se == 16; $e{end_dt} = substr($se, 0, 19) }
        } else {
            $e{start_date} = $sd;
            require DateTime;
            my ($y, $m, $d) = split /-/, $sd;
            my $dt = eval { DateTime->new(year => $y, month => $m, day => $d)->add(days => 1) };
            $e{end_date} = $dt->ymd if $dt;
        }
        push @ev, \%e;
    }
    return \@ev;
}

1;
