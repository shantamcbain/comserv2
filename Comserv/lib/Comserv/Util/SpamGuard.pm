package Comserv::Util::SpamGuard;
use strict;
use warnings;
use utf8;

# One shared spam guard for every public entry point that turns visitor text
# into mail or a HelpDesk ticket (CSC-20261012-0420):
#   - HelpDesk /HelpDesk/contact (all SiteNames incl. "none"/default)
#   - HelpDesk new ticket form
#   - AI2 HelpDeskTicketCreate and AI2 Actions create_helpdesk_ticket
# Pure class methods (no $c) so they are testable; callers keep their own
# honeypot / rate-limit / Turnstile layers (HelpDesk::_spam_guard_fail).
#
#   looks_like_spam($subject, $body)            -> 1/0 known crypto/phish patterns
#   score($subject, $body, $email, $is_guest)   -> ($score, \@reasons)
#   verdict(subject=>, body=>, email=>, guest=>, threshold=>5) -> { score, reasons, quarantine }
#   clean_header($value)                        -> value with CR/LF/control chars removed
#   valid_email($email)                         -> 1/0
# Spam is QUARANTINED by callers (status 'quarantine', no mail, no webhook),
# never deleted, so staff can release a false positive at /HelpDesk/admin/quarantine.

our $DEFAULT_THRESHOLD = 5;

sub looks_like_spam {
    my ($class, $subject, $body) = @_;
    my $text = join(' ', map { defined $_ ? $_ : '' } ($subject, $body));
    # Normalize lookalikes used by BMASTER-20260901-6247 class spam
    $text =~ s/\x{2116}/No./g;  # №
    $text = lc($text);
    $text =~ s/\s+/ /g;

    # Crypto/phishing patterns (CSC-20260830-2900, BMASTER-20260901-6247, WEAVERBECK-20260902-0936)
    my @patterns = (
        qr/graph\.org/i,
        qr/coinbase/i,
        qr/\bbitcoin\b/i,
        qr/bitcoin[\s\-_]?mining/i,
        qr/cloud.?mining/i,                 # Cloud-Mining-08-27 etc. (WEAVERBECK-20260902-0936)
        qr/one.?message.?for.?you/i,        # ONE MESSAGE for you (WEAVERBECK spam)
        qr/open\s*[-=]*>+/i,               # OPEN ->>> graph.org
        qr/\bbtc\b/i,
        qr/you.?have.?a.?new.?bitcoin/i,
        qr/wallet.?transfer/i,
        qr/claim.?your.?crypto/i,
        qr/hs=[0-9a-f]{16,}/i,
        qr/no\.\s*[a-z]?\d{3,}/i,          # Transfer No. V8998 / № V8998
        qr/transfer\s+(?:no\.?|n[o0]\.?|#)\s*[a-z]?\d+/i,
        qr/next\s*-*>+/i,                  # NEXT ->> graph.org
        qr/open\s*[⚡]/i,
    );
    for my $re (@patterns) {
        return 1 if $text =~ $re;
    }
    # Extreme link density / short-link spam
    my $links = () = $text =~ m{https?://}g;
    return 1 if $links >= 3 && length($text) < 400;
    # Bare graph.org / shortener without scheme still counts as a link bait
    my $bare = () = $text =~ m{\b[\w\-]+\.(?:org|com|net|io)/\S+}g;
    return 1 if $bare >= 1 && $text =~ /(?:coinbase|bitcoin|mining|transfer|wallet|cloud)/i;

    # Link-only / promo profile detection (CSC-20260911-6270)
    my @urls;
    while ($text =~ m{(?:https?://|www\.)\S+}g) {
        push @urls, $&;
    }
    if (@urls) {
        my $stripped = $text;
        for my $u (@urls) {
            my $q = quotemeta($u);
            $stripped =~ s/$q//g;
        }
        $stripped =~ s/\s+/ /g;
        $stripped =~ s/^\s+|\s+$//g;
        my $remain = length($stripped);
        return 1 if $remain < 40;
        if ($remain < 80 && $text =~ /(?:profile|follow me|check out my|visit my|subscribe|followers|promo|discount)/) {
            return 1;
        }
        my $url_len = 0;
        $url_len += length($_) for @urls;
        my $tlen = length($text);
        return 1 if $tlen > 0 && ($url_len / $tlen) >= 0.55;
    }
    return 0;
}

sub score {
    my ($class, $subject, $body, $email, $is_guest) = @_;
    my $text = join ' ', map { $_ // '' } ($subject, $body);
    my ($score, @why) = (0);
    my $add = sub { my ($n, $r) = @_; $score += $n; push @why, $r };

    $add->(10, 'known_spam_pattern') if $class->looks_like_spam($subject, $body);
    my $links = () = $text =~ m{https?://}gi;
    $add->($links >= 3 ? 3 : $links, "links=$links") if $links;
    $add->(2, 'shortener') if $text =~ m{\b(?:bit\.ly|tinyurl\.com|t\.me|graph\.org|telegra\.ph|rb\.gy|cutt\.ly)\b}i;
    # Blog-paste / anonymous-publish sites used for lure links (CSC-20261012-0420)
    $add->(2, 'paste_site') if $text =~ m{\b(?:pastebin\.com|paste\.ee|rentry\.(?:co|org)|justpaste\.it|teletype\.in|write\.as|telegra\.ph|graph\.org|controlc\.com|dpaste\.\w+|hastebin\.com)\b}i;
    my @kw = ($text =~ /\b(crypto|bitcoin|btc|usdt|wallet|airdrop|casino|viagra|cialis|seo services|backlinks?|guest post|loan offer|forex|investment opportunity|telegram|whatsapp me|binance|metamask)\b/gi);
    $add->(scalar(@kw) * 2 > 6 ? 6 : scalar(@kw) * 2, 'keywords=' . join(',', map { lc } @kw)) if @kw;
    if ($is_guest) {
        # Guests posting links: CSC-20261012-0420 promo subject + one paste-site link.
        # +3 alone (with links=1 -> 4) stays under the default threshold 5, so a real
        # guest who pastes one normal link still gets through.
        $add->(3, 'guest_link') if $links;
        $add->(1, 'guest_no_email') unless defined $email && $email =~ /\@/;
        $add->(1, 'disposable_email') if defined $email && $email =~ /\@(?:mailinator|guerrillamail|10minutemail|tempmail|yopmail|sharklasers)\./i;
    }
    my $letters = () = $text =~ /[A-Za-z]/g;
    my $caps    = () = $text =~ /[A-Z]/g;
    $add->(1, 'mostly_caps') if $letters > 30 && $caps / $letters > 0.6;
    $add->(1, 'cyrillic_mix') if $text =~ /\p{Cyrillic}/ && $text =~ /[A-Za-z]{4}/;
    $add->(1, 'html_markup') if $text =~ /<a\s+href|\[url=/i;
    return ($score, \@why);
}

sub verdict {
    my ($class, %a) = @_;
    my $th = defined $a{threshold} ? $a{threshold} : $DEFAULT_THRESHOLD;
    my ($score, $why) = $class->score($a{subject}, $a{body}, $a{email}, $a{guest});
    return { score => $score, reasons => $why, quarantine => ($score >= $th ? 1 : 0) };
}

# Header-injection guard: anything that ends up in a mail header (name, email,
# subject) loses CR, LF, NUL and other control chars, and is capped in length.
sub clean_header {
    my ($class, $v, $max) = @_;
    return '' unless defined $v;
    $v =~ s/[\r\n]+/ /g;
    $v =~ s/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]//g;
    $v =~ s/\s+/ /g;
    $v =~ s/^\s+|\s+$//g;
    $max ||= 200;
    $v = substr($v, 0, $max) if length($v) > $max;
    return $v;
}

sub valid_email {
    my ($class, $e) = @_;
    return 0 unless defined $e && length($e) <= 254;
    return 0 if $e =~ /[\r\n\s<>,;"]/;
    return $e =~ /^[A-Za-z0-9._%+'-]+\@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}$/ ? 1 : 0;
}

1;
