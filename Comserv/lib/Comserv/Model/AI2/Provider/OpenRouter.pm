package Comserv::Model::AI2::Provider::OpenRouter;

use Moose;
extends 'Catalyst::Model';
use namespace::autoclean -except => [qw(try catch finally)];  # keep Try::Tiny subs (Perl 5.40)

use Try::Tiny;
use LWP::UserAgent;
use JSON qw(decode_json encode_json);

use Comserv::Util::Logging;

has 'logging' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Comserv::Util::Logging->instance },
);

# ===================================================================
# AI2::Provider::OpenRouter — OpenAI-compatible aggregator.
#
# OpenRouter exposes an OpenAI-compatible API at https://openrouter.ai/api/v1.
# Mirrors the Grok provider: admin-gated key resolution from UserApiKeys
# (service => 'openrouter'), lists /api/v1/models, returns the catalog.
# Chat completion is handled generically by v1 Model::AI::Provider's
# OpenAI-compatible client (endpoint guessed from the service name) once the
# Router selects an 'openrouter' model. No raw SQL.
# ===================================================================

sub _resolve_api_key {
    my ($self, $c, $api_key, %o) = @_;

    # Explicit key passed (already decrypted) takes precedence.
    return $api_key if $api_key && length $api_key;

    # K8s secret, then env var.
    my $k8s_secret = '/run/secrets/openrouter_api_key';
    if (-e $k8s_secret && open my $fh, '<', $k8s_secret) {
        my $k = do { local $/; <$fh> };
        close $fh;
        chomp($k);
        return $k if $k && length $k;
    }
    return $ENV{OPENROUTER_API_KEY} if $ENV{OPENROUTER_API_KEY} && length $ENV{OPENROUTER_API_KEY};

    # 2026-10-16: servers started without a login shell (Git page button,
    # systemd) miss OPENROUTER_API_KEY from ~/.bashrc. Fall back to the
    # workstation secret file (one line, chmod 600) before the DB lookup.
    if (my $home = $ENV{HOME}) {
        for my $f ("$home/.comserv/secrets/openrouter_api_key") {
            next unless -r $f && open(my $fh, '<', $f);
            my $k;
            while (my $l = <$fh>) {
                if ($f =~ /\.env$/) { ($k) = $l =~ /^\s*(?:export\s+)?OPENROUTER_API_KEY\s*=\s*['"]?([^'"\s]+)/ and last; }
                else { chomp $l; $k = $l if length $l; last; }
            }
            close $fh;
            return $k if $k && length $k;
        }
    }

    # 2026-10-17: every logged-in user's chat may use a shared key (it is only
    # used server-side, never shown). Order: user's own row -> a row tagged with
    # this site_id -> the workstation-wide row (site_id NULL, newest first).
    # user_id is NOT NULL in user_api_keys, so "shared" = site/global scope.
    # 2026-10-21: no session (usage_live, daily eval, guard) -> skip the user row
    # and use the shared rows, then the workstation key files.
    # Chat stays logged-in only; system => 1 (status/eval/guard) may use shared keys.
    my $user_id = eval { $c->session->{user_id} };
    # 2026-10-24 (Shanta, #2605): public-site Guests may chat on the shared
    # workstation row, FREE models only (enforced in _chat_http). Opt-in: the
    # caller passes guest => 1 AND the /ai2/chat controller has marked this
    # request (stash ai_guest_chat). Never opens the generic no-user path.
    my $guest_ok = !defined $user_id && $o{guest} && is_guest_chat($c);
    return undef unless defined $user_id || $o{system} || $guest_ok;
    my $key_obj = eval { _db_key($c, $user_id) };
    my $k = $key_obj && $key_obj->api_key_encrypted ? eval { $key_obj->get_api_key() } : undef;
    return $k if $k && length $k;
    return $o{system} ? shared_file_key() : undef;
}

# ---- Guest chat (public sites, no session user_id) -----------------------
# Only the /ai2/chat controller sets stash ai_guest_chat, and only when the
# session has no user_id. Background/no-session callers never carry the flag.
our $GUEST_LIMIT  = 10;      # chat calls per IP per window
our $GUEST_WINDOW = 3600;    # seconds
my %GUEST_HITS;              # ip => [epoch, ...]  (per process, in memory)

sub is_guest_chat {
    my ($c) = @_;
    return 0 unless $c;
    my $uid = eval { $c->session->{user_id} };
    return 0 if defined $uid && length $uid;
    return eval { $c->stash->{ai_guest_chat} } ? 1 : 0;
}

# Free = OpenRouter ':free' id or the app's FREE_MODEL; never a PaidBlock id.
sub guest_model_ok {
    my ($model) = $_[-1];
    return 0 unless defined $model && length $model;
    $model =~ s/^[^|]+\|//;
    require Comserv::Util::AI::PaidBlock;
    return 0 if Comserv::Util::AI::PaidBlock->blocked_on_openrouter($model);
    return ($model =~ /:free$/i || $model eq $Comserv::Util::AI::PaidBlock::FREE_MODEL) ? 1 : 0;
}

# 1 = allowed (and counted), 0 = over the per-IP limit. $now is injectable.
sub guest_rate_ok {
    my ($ip, $now) = @_;
    $ip = 'unknown' unless defined $ip && length $ip;
    $now //= time;
    if (keys %GUEST_HITS > 5000) {
        for my $k (keys %GUEST_HITS) {
            @{ $GUEST_HITS{$k} } = grep { $now - $_ < $GUEST_WINDOW } @{ $GUEST_HITS{$k} };
            delete $GUEST_HITS{$k} unless @{ $GUEST_HITS{$k} };
        }
    }
    my $h = $GUEST_HITS{$ip} ||= [];
    @$h = grep { $now - $_ < $GUEST_WINDOW } @$h;
    return 0 if @$h >= $GUEST_LIMIT;
    push @$h, $now;
    return 1;
}
sub _guest_rate_reset { %GUEST_HITS = () }

# Workstation files, same names as script/load_shared_keys.pl, plus ~/.hermes/.env.
# Returns the value only; never logged.
sub shared_file_key {
    my $home = shift // $ENV{HOME} or return undef;
    for my $f ("$home/.comserv/secrets/api_keys.env", "$home/.bashrc", "$home/.hermes/.env") {
        next unless -r $f && open(my $fh, '<', $f);
        my $k;
        while (my $l = <$fh>) {
            ($k) = $l =~ /^\s*(?:export\s+)?OPENROUTER_API_KEY\s*=\s*['"]?([^'"\s#]+)/ or next;
            last if $k =~ /^\S{8,}$/ && $k !~ /^\$/;
            undef $k;
        }
        close $fh;
        return $k if $k;
    }
    return undef;
}

sub _db_key {
    my ($c, $user_id) = @_;
    my $schema = eval { $c->model('DBEncy')->schema } or return undef;
    my $rs = $schema->resultset('UserApiKeys');
    my %base = (service => 'openrouter', is_active => '1');
    my %newest = (order_by => { -desc => 'updated_at' }, rows => 1);
    my $site_id = eval { $c->stash->{site_id} } // eval { $c->session->{site_id} };
    my $key_obj = (defined $user_id ? $rs->search({ %base, user_id => $user_id }, \%newest)->first : undef)
        || (defined $site_id ? $rs->search({ %base, site_id => $site_id }, \%newest)->first : undef)
        || $rs->search({ %base, site_id => undef }, \%newest)->first;
    return $key_obj;
}

sub list_models {
    my ($self, $c, $api_key) = @_;

    $api_key = $self->_resolve_api_key($c, $api_key);
    return { success => 0, error => 'No active openrouter API key found' } unless $api_key;

    my $ua  = LWP::UserAgent->new(timeout => 8);
    my $res = try {
        $ua->get('https://openrouter.ai/api/v1/models',
            'Authorization' => "Bearer $api_key",
            'Content-Type'  => 'application/json',
        );
    } catch {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'openrouter_list_models', "OpenRouter request failed: $_");
        return undef;
    };
    return { success => 0, error => 'Provider API error' } unless $res && $res->is_success;

    my $data = try { decode_json($res->decoded_content) } catch { undef };
    return { success => 0, error => 'Bad JSON from provider' } unless $data;

    # OpenRouter returns { data: [ { id, name, pricing => { prompt, completion,
    #   request, image, web_search, ... }, ... } ] }. Pricing values are USD
    # *per token* as strings (e.g. "0.000001"). We keep the raw pricing object
    # and also expose per-1M-token USD numbers so downstream surfaces can sort,
    # filter and display by real cost without re-deriving it. (AIMPS-P1 / #253)
    my @out = map {
        my $m = $_;
        my $p = $m->{pricing} || {};
        my $pp = _per_million($p->{prompt});
        my $pc = _per_million($p->{completion});
        {
            id             => $m->{id},
            label          => ($m->{name} || $m->{id}),
            pricing        => $p,                       # raw hash, kept intact
            price_prompt     => $pp,                    # USD / 1M input tokens
            price_completion => $pc,                    # USD / 1M output tokens
        }
    } grep { $_->{id} }
      @{ $data->{data} || [] };

    return { success => 1, models => \@out, count => scalar @out };
}

# OpenRouter reports per-token USD prices as strings; convert to per-1M USD.
# Returns a number (0 when missing/non-numeric).
sub _per_million {
    my ($v) = @_;
    return 0 unless defined $v && $v =~ /^-?\d+(?:\.\d+)?$/;
    return $v * 1_000_000;
}

# Chat completion against OpenRouter (OpenAI-compatible). Returns the v2 shape.
sub _chat_http {
    my ($self, $c, %args) = @_;

    # 2026-10-15 last-line guard: OpenRouter is never called for any grok id
    # or deepseek-v4-pro. Callers should have rerouted grok to Super Grok.
    my $guest = is_guest_chat($c);
    if ($guest) {
        unless (guest_model_ok($args{model})) {
            eval { $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'openrouter_chat',
                "Guest chat refused non-free model " . ($args{model} // '(none)')) };
            return { success => 0, error => 'Guests can use free models only. Please log in to use other models.' };
        }
        require Comserv::Util::AI::GuestGuard;
        my $ip = Comserv::Util::AI::GuestGuard->client_ip($c);
        unless (guest_rate_ok($ip)) {
            eval { $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'openrouter_chat',
                "Guest chat rate limit hit for " . ($ip // 'unknown')) };
            return { success => 0, rate_limited => 1,
                     error => "You've reached the guest chat limit for now ($GUEST_LIMIT messages per hour). Please try again later, or log in to keep chatting." };
        }
    }

    require Comserv::Util::AI::PaidBlock;
    if (Comserv::Util::AI::PaidBlock->blocked_on_openrouter($args{model} // '')) {
        my $was = $args{model};
        $args{model} = $Comserv::Util::AI::PaidBlock::FREE_MODEL;
        eval { $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'openrouter_chat',
            "Blocked paid OpenRouter model $was; sent $args{model} instead") };
    }

    my $api_key = $self->_resolve_api_key($c, $args{api_key}, ($guest ? (guest => 1) : ()));
    unless ($api_key) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'openrouter_chat',
            "No active openrouter API key found (user=" . ($c->session->{username} // 'Guest') . ")");
        return { success => 0, error => ($guest ? 'Chat is not available to guests right now. Please log in.' : 'No active openrouter API key found') };
    }
    # A guest never supplies a key and never sees why a call failed upstream.

    my $messages = $args{messages} || [];
    return { success => 0, error => 'No messages provided' }
        unless ref($messages) eq 'ARRAY' && @$messages;

    my $harm = eval {
        require Comserv::Util::AI::HarmRefusal;
        Comserv::Util::AI::HarmRefusal::scan_messages($messages);
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'openrouter_chat',
            "HarmRefusal failed closed: $@");
        return { success => 0, refused => 1, error => 'Chat safety check failed. The question was not sent.' };
    }
    if ($harm) {
        $self->logging->log_with_details($c, 'warning', __FILE__, __LINE__, 'openrouter_chat',
            Comserv::Util::AI::HarmRefusal::log_line($harm, eval { $c->session->{user_id} }));
        return Comserv::Util::AI::HarmRefusal::reply_hash($harm);
    }

    my $model = $args{model};
    $model =~ s/^[^|]+\|// if $model;   # drop any "provider|" prefix
    unless ($model) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'openrouter_chat',
            "No model specified for OpenRouter chat (user=" . ($c->session->{username} // 'Guest') . ")");
        return { success => 0, error => 'No model specified' };
    }
    my $payload = {
        model       => $model,
        messages    => $messages,
        temperature => 0.7,
        max_tokens  => $args{max_tokens} // 4096,
        # Ask OpenRouter for the billed cost of this call (usage.cost) so the
        # Ledger audit row carries real dollars, not a token-rate guess.
        usage       => { include => JSON::true },
    };

    my $ua = LWP::UserAgent->new(timeout => 180);
    $ua->agent('Comserv-AI/1.0');
    my $req = HTTP::Request->new(POST => 'https://openrouter.ai/api/v1/chat/completions');
    $req->header('Content-Type'  => 'application/json');
    $req->header('Authorization' => "Bearer $api_key");
    $req->content(encode_json($payload));

    my $res = try { $ua->request($req) } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'openrouter_chat', "OpenRouter request threw: $_ (model=$model, user="
            . ($c->session->{username} // 'Guest') . ")");
        return undef;
    };
    unless ($res && $res->is_success) {
        my $status = $res ? $res->status_line : 'no response';
        my $body   = $res ? substr($res->decoded_content // '', 0, 600) : '';
        # Surface OpenRouter's own error text (e.g. "X is not a valid model ID")
        # in the returned error, not just the HTTP status. The caller logs this
        # string into the error-audit todo, and a bare "400 Bad Request" gives
        # no way to tell a bad model id from a bad key or a rate limit.
        my $detail = try {
            my $j = decode_json($res->decoded_content // '{}');
            ref($j->{error}) eq 'HASH' ? $j->{error}{message} : $j->{error};
        } catch { undef };
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'openrouter_chat',
            "OpenRouter HTTP failure: $status (model=$model, user="
            . ($c->session->{username} // 'Guest') . ") body=$body");
        return { http_sent => 1, http_status => $status, success => 0, error => "OpenRouter provider error: $status"
                                      . ($detail ? " - $detail" : '') };
    }

    my $data = try { decode_json($res->decoded_content) } catch { undef };
    unless ($data) {
        my $body = substr($res->decoded_content // '', 0, 600);
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'openrouter_chat', "Bad JSON from OpenRouter (model=$model) body=$body");
        return { http_sent => 1, success => 0, error => 'Bad JSON from OpenRouter' };
    }

    my $text = '';
    if ($data->{choices} && ref($data->{choices}) eq 'ARRAY' && @{$data->{choices}}) {
        my $msg = $data->{choices}[0]{message} // {};
        $text = $msg->{content} // '';
        # Some free models (e.g. nemotron) return null content and put text in
        # reasoning / reasoning_content, or content as a list of parts.
        if ((!defined $text || $text eq '') && ref($msg) eq 'HASH') {
            $text = $msg->{reasoning_content} // $msg->{reasoning} // '';
        }
        if (ref($text) eq 'ARRAY') {
            $text = join('', map {
                ref($_) eq 'HASH' ? ($_->{text} // $_->{content} // '') : (defined $_ ? "$_" : '')
            } @$text);
        }
        $text = '' unless defined $text;
    }
    $text =~ s/^\s+|\s+$//g if defined $text;
    unless (defined $text && length $text) {
        my $body = substr($res->decoded_content // '', 0, 600);
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'openrouter_chat',
            "OpenRouter empty content (model=$model, user="
            . ($c->session->{username} // 'Guest') . ") body=$body");
        return {
            http_sent => 1, id => $data->{id}, upstream => $data->{provider},
            success => 0,
            error   => 'OpenRouter returned empty content',
            model   => $data->{model} || $model,
            usage   => $data->{usage} || {},
        };
    }
    return { http_sent => 1, id => $data->{id}, upstream => $data->{provider},
             success => 1, response => $text, model => $data->{model} || $model, usage => $data->{usage} || {} };
}

# Admin-only sync: returns the live catalog (UI stores it in metadata if desired).
sub sync_models {
    my ($self, $c, $api_key) = @_;
    return $self->list_models($c, $api_key);
}

# ===================================================================
# chat() — every OpenRouter chat call goes through here and is written to
# the Ledger (ai_usage_logs, request_type 'openrouter_call') with branch,
# sitename, user and a purpose tag, whether or not the caller also logs its
# own feature row. These audit rows are excluded from the usage totals
# (UsageMonitor EXCLUDED_REQUEST_TYPES) and used for the unlogged-spend
# reconciliation against OpenRouter's billed spend. Pass purpose => '...'
# to tag a call explicitly; otherwise it is derived from the caller.
# ===================================================================
sub chat {
    my ($self, $c, %args) = @_;
    my $t0 = eval { require Time::HiRes; Time::HiRes::time() } || time;
    my $r  = $self->_chat_http($c, %args);
    if (ref $r eq 'HASH' && delete $r->{http_sent}) {
        my $ms = int(((eval { Time::HiRes::time() } || time) - $t0) * 1000);
        $self->_audit_ledger($c, %args, result => $r, duration_ms => $ms);
    }
    return $r;
}

our %PURPOSE_BY_SUB = (
    'Comserv::Controller::AI::generate'      => 'ai_editor_generate',
    'Comserv::Controller::AI::chat'          => 'ai_chat',
    'Comserv::Controller::AI2::test_model'   => 'model_test',
);

sub purpose_from_chain {
    my ($chain) = @_;
    for my $sub (@{ $chain || [] }) {
        return $PURPOSE_BY_SUB{$sub} if $PURPOSE_BY_SUB{$sub};
        return 'focus_tune'  if $sub =~ /FocusTune|focustune/i;
        return 'title'       if $sub =~ /title/i;
        return 'eval'        if $sub =~ /Eval/;
        return 'organizer'   if $sub =~ /Organizer|DecisionRank|TodaysFocus/i;
    }
    for my $sub (@{ $chain || [] }) {
        next if $sub =~ /::Router::|::Chat::/;
        (my $short = $sub) =~ s/^Comserv:://;
        return lc join '_', grep { length } split /::/, $short;
    }
    return @{ $chain || [] } ? 'router' : 'unknown';
}

sub _audit_ledger {
    my ($self, $c, %a) = @_;
    return if $ENV{COMSERV_NO_OR_AUDIT};
    my $ok = eval {
        my $r = $a{result} || {};
        my $u = ref $r->{usage} eq 'HASH' ? $r->{usage} : {};
        my @chain;
        for my $i (1 .. 12) {
            my @f = caller($i) or last;
            next if $f[3] =~ /Provider::OpenRouter::|^Try::Tiny|__ANON__|^\(eval\)/;
            push @chain, $f[3];
            last if @chain >= 4;
        }
        my $purpose = $a{purpose} // purpose_from_chain(\@chain);
        my $cost = $u->{cost};
        my $model = $r->{model} || $a{model} || 'unknown';
        $model =~ s/^[^|]+\|//;
        my $schema = $c->model('DBEncy')->schema or die "no schema\n";
        require Comserv::Model::AI::Usage;
        my $meta = {
            audit => 1, purpose => $purpose, caller => join(' < ', @chain),
            cost_source => (defined $cost ? 'openrouter_usage' : 'none'),
            (defined $r->{id}       ? (generation_id => $r->{id})       : ()),
            (defined $r->{upstream} ? (upstream      => $r->{upstream}) : ()),
            (ref $u->{prompt_tokens_details} eq 'HASH' && defined $u->{prompt_tokens_details}{cached_tokens}
                ? (cached_tokens => 0 + $u->{prompt_tokens_details}{cached_tokens}) : ()),
            branch   => (eval { Comserv::Model::AI::Usage::_app_branch($c) } || undef),
            sitename => (eval { $c->session->{SiteName} } || eval { $c->stash->{SiteName} } || undef),
            username => (eval { $c->session->{username} } || undef),
        };
        delete $meta->{$_} for grep { !defined $meta->{$_} } keys %$meta;
        my $pt = 0 + ($u->{prompt_tokens} // 0);
        my $ct = 0 + ($u->{completion_tokens} // 0);
        $schema->resultset('AiUsageLog')->create({
            user_id            => (eval { $c->session->{user_id} } || undef),
            site_id            => (eval { $c->session->{SiteID} } || undef),
            provider           => 'openrouter',
            model              => substr($model, 0, 100),
            prompt_tokens      => $pt,
            completion_tokens  => $ct,
            total_tokens       => 0 + ($u->{total_tokens} // ($pt + $ct)),
            estimated_cost_usd => (defined $cost ? 0 + $cost : 0),
            duration_ms        => $a{duration_ms},
            request_type       => 'openrouter_call',
            status             => ($r->{success} ? 'success' : 'error'),
            error_message      => ($r->{success} ? undef : substr($r->{error} // '', 0, 500)),
            metadata           => encode_json($meta),
        });
        1;
    };
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'openrouter_audit',
        "Ledger audit row failed: $@") unless $ok;
    return $ok ? 1 : 0;
}

__PACKAGE__->meta->make_immutable;

1;
