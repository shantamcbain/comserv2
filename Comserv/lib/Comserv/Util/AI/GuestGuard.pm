package Comserv::Util::AI::GuestGuard;
# 2026-10-24 (Shanta, #2605): hard limits for public-site Guest chat.
# Pure functions (no DB, no keys). Everything a Guest request may influence
# is scrubbed here; model, guest flag, free-only rule and role come from
# server-side state only.
use strict;
use warnings;
use Comserv::Util::Logging;

our $REFUSAL = "Sorry, I can't help with that request.";

# Request fields a Guest may never set. Dropped (not honoured) on /ai2/chat.
our @STRIP = qw(model provider system user_id userid username roles role site site_id
                sitename SiteID agent_id skip_role_prompt skip_app_writes surface
                phase route user_picked grounding creative project_id task_id
                conversation_id audio_file_id transcript_file_id use_search
                page_links api_key key session admin is_admin);

# Free text / params that look like path traversal, admin routes, SQL or
# template injection, or tool/command invocation, or prompt-injection.
my @PATTERNS = (
    [ traversal  => qr{(?:\.\.[/\\]|%2e%2e|%252e|\.\.%2f|\.\.%5c|%00|\x00|/etc/passwd|/proc/self)}i ],
    [ admin_route=> qr{(?:^|[\s"'(=:])(?:/admin|/?ai2/(?:save_file|load_file|file_tree|git_|hermes|token[-_]login|diagnostics)|api/todo|todo/(?:done|open_log|addtodo)|user/(?:login|admin)|ai/action)\b}i ],
    [ sql        => qr{(?:\bunion\s+(?:all\s+)?select\b|\bselect\b[^.\n]{0,60}\bfrom\b\s+\w+|;\s*(?:drop|delete|insert|update|alter|truncate)\b|'\s*or\s*'?\d*'?\s*=\s*'?\d|--\s*$|\binformation_schema\b|\bsleep\s*\(\s*\d)}i ],
    [ template   => qr{(?:\[%|%\]|\{\{|\}\}|<%|%>|\$\{|<script\b|\bTemplate::|\bFILE\s*\()}i ],
    [ injection  => qr{(?:ignore|disregard|forget|override)\s+(?:all\s+|any\s+|the\s+|your\s+)*(?:previous|prior|above|earlier|system|safety)?\s*(?:instructions?|prompts?|rules?|restrictions?)|reveal\s+(?:your\s+|the\s+)?(?:system\s+)?prompt|\byou\s+are\s+now\b.{0,40}\b(?:admin|root|developer|unrestricted)|\b(?:developer|admin|sudo)\s+mode\b|\bjailbreak\b|api[_ ]?key|OPENROUTER_API_KEY}i ],
    [ tool       => qr{(?:\b(?:read|open|cat|show|list)\s+(?:the\s+)?(?:file|source|codebase|filesystem)\b|\b(?:run|execute|exec)\s+(?:this\s+|the\s+)?(?:command|shell|script|code|sql)\b|\bgit\s+(?:commit|push|stage|status)\b|\bfetch\s+(?:the\s+)?(?:url|page)\b|\bcurl\s|\bwget\s|\bsudo\s|\brm\s+-)}i ],
);

sub refusal { $REFUSAL }

# Returns the reason string when $text looks hostile, else undef.
sub detect_attack {
    my ($class, $text) = @_;
    return undef unless defined $text && !ref $text && length $text;
    for my $p (@PATTERNS) {
        return $p->[0] if $text =~ $p->[1];
    }
    return undef;
}

# Remove client-supplied overrides and clean history. Returns ($clean, $reason).
# $clean is a NEW hashref holding only prompt + sanitized history.
sub scrub_request {
    my ($class, $in) = @_;
    $in = {} unless ref $in eq 'HASH';
    my $prompt = defined $in->{prompt} && !ref $in->{prompt} ? $in->{prompt} : '';
    $prompt = substr($prompt, 0, 4000);
    my @hist;
    if (ref $in->{history} eq 'ARRAY') {
        for my $m (grep { ref $_ eq 'HASH' } @{ $in->{history} }) {
            my $r = lc($m->{role} // '');
            next unless $r eq 'user' || $r eq 'assistant';   # never client-supplied 'system'/'tool'
            my $t = defined $m->{content} && !ref $m->{content} ? substr($m->{content}, 0, 2000) : '';
            push @hist, { role => $r, content => $t } if length $t;
        }
        @hist = @hist[-6 .. -1] if @hist > 6;
    }
    my $reason = $class->detect_attack($prompt);
    unless ($reason) {
        for my $h (@hist) { $reason = $class->detect_attack($h->{content}) and last; }
    }
    # Any other client-controlled string param is also checked (page_path etc.).
    unless ($reason) {
        my %dropped = map { $_ => 1 } @STRIP;   # dropped anyway; not scanned
        for my $k (grep { !ref $in->{$_} && defined $in->{$_} && $_ ne 'prompt' && !$dropped{$_} } keys %$in) {
            my $v = $in->{$k};
            next unless $v =~ /\.\.|%2e|%00|\x00|\[%|\{\{|<%|\bunion\b.*\bselect\b/i
                     || $v =~ m{^/?admin\b}i;
            $reason = 'param_' . ($k =~ /^\w{1,30}$/ ? $k : 'x');
            last;
        }
    }
    return ({ prompt => $prompt, history => \@hist, stripped => [ grep { exists $in->{$_} } @STRIP ] }, $reason);
}

# Real client IP. X-Forwarded-For is honoured only when the TCP peer is a
# trusted proxy (env COMSERV_TRUSTED_PROXIES, default loopback); the rightmost
# untrusted hop is used so a client-chosen header cannot change the bucket.
sub client_ip {
    my ($class, $c) = @_;
    my $peer = eval { $c->req->env->{REMOTE_ADDR} } // eval { $c->req->address } // '';
    my %trusted = map { $_ => 1 } grep { length }
        split /[\s,]+/, ($ENV{COMSERV_TRUSTED_PROXIES} // '127.0.0.1,::1');
    return $peer || 'unknown' unless $trusted{$peer};
    my $xff = eval { $c->req->header('X-Forwarded-For') } // '';
    my @hops = reverse grep { length } map { s/^\s+|\s+$//gr } split /,/, $xff;
    for my $h (@hops) {
        next unless $h =~ /^(?:\d{1,3}(?:\.\d{1,3}){3}|[0-9a-fA-F:]{2,39})$/;
        next if $trusted{$h};
        return $h;
    }
    return $peer || 'unknown';
}

# Existing app logger; text truncated, never keys.
sub log_block {
    my ($class, $c, $ip, $reason, $text) = @_;
    $text = defined $text ? substr($text, 0, 120) : '';
    $text =~ s/[\r\n\t]+/ /g;
    $text =~ s/sk-[A-Za-z0-9_\-]{8,}/[redacted]/g;
    eval {
        Comserv::Util::Logging->instance->log_with_details($c, 'warning', __FILE__, __LINE__,
            'guest_guard', "Blocked guest chat ip=" . ($ip // 'unknown') . " reason=$reason text='$text'");
    };
}

1;
