package Comserv::Util::AI::UserKeys;
# Any-provider user API keys (Oct 30 2026, Shanta: "any user can add their own key for any provider and pay their own
# AI cost; no schema change for a new provider"). Pure validation + the one lookup helper (get_user_key).
#
# Storage: user_api_keys.service is a free lowercase slug (varchar(64) once schema compare applies Result/UserApiKeys.pm),
# key_type (chat|management|billing|...), optional base_url (OpenAI-compatible endpoint) and label.
# Until that migration is applied the new columns are absent: every query here selects explicit columns and only
# filters on key_type/base_url when a probe proves the columns exist (same pattern as Util::AI::Ledger).
#
# Key values are never logged, returned in errors or put in templates.
use strict;
use warnings;
use Socket qw(inet_aton);

our $SLUG_RE     = qr/^[a-z0-9_.-]{2,64}$/;
our $KEY_TYPE_RE = qr/^[a-z0-9_-]{2,32}$/;
our @KEY_TYPES   = qw(chat management billing search embeddings);
# Known providers for the form (slug => label). Anything else goes in via "Other".
our @KNOWN = (
    [ openrouter => 'OpenRouter' ],           [ grok      => 'Grok / x.ai (API key)' ],
    [ openai     => 'OpenAI' ],               [ anthropic => 'Anthropic (Claude)' ],
    [ claude     => 'Claude (legacy name)' ], [ gemini    => 'Gemini (Google)' ],
    [ cohere     => 'Cohere' ],               [ groq      => 'Groq' ],
    [ mistral    => 'Mistral' ],              [ deepseek  => 'DeepSeek' ],
    [ together   => 'Together AI' ],          [ ollama    => 'Ollama (ollama.com)' ],
    [ brave      => 'Brave Search' ],         [ searxng   => 'SearXNG (self-hosted search)' ],
);
our %ALIAS = (xai => 'grok', 'x.ai' => 'grok');   # one row name per provider

# Owner/system keys: rows of this user (user_id is NOT NULL in the DB). Only these may serve other users (old "global" scope
# picked ANY user's site_id-NULL row, which would bill one user's own key to everybody).
sub owner_user_id { my $v = $ENV{COMSERV_AI_OWNER_USER_ID}; return (defined $v && $v =~ /^\d+$/) ? $v : 178 }

sub normalize_service {
    my ($class, $s) = @_;
    return undef unless defined $s;
    $s = lc $s; $s =~ s/^\s+|\s+$//g;
    return $ALIAS{$s} // $s;
}
sub valid_service  { my ($class, $s) = @_; return defined $s && $s =~ $SLUG_RE ? 1 : 0 }
sub valid_key_type { my ($class, $t) = @_; return defined $t && $t =~ $KEY_TYPE_RE ? 1 : 0 }

# IPv4 private / loopback / link-local; IPv6 loopback / ULA / link-local.
sub _is_private_ip {
    my ($h) = @_;
    if ($h =~ /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/) {
        return 0 if grep { $_ > 255 } ($1, $2, $3, $4);
        return 1 if $1 == 10 || $1 == 127 || ($1 == 192 && $2 == 168) || ($1 == 172 && $2 >= 16 && $2 <= 31);
        return 0;
    }
    return 1 if $h eq '::1' || $h =~ /^f[cd][0-9a-f]{2}:/i;
    return 0;
}
# Blocked even over https: cloud metadata / link-local / 0.0.0.0 / any literal IP that is not private.
sub _is_blocked_ip {
    my ($h) = @_;
    return 1 if $h =~ /^169\.254\./ || $h =~ /^0\./ || $h eq '0.0.0.0' || $h =~ /^fe80:/i || $h =~ /^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\./;
    return 0;
}

# validate_base_url($url) -> (normalized_url, undef) | (undef, 'why')
# Rule (SSRF): https to a public host name is allowed; http ONLY to localhost / a private IP literal / *.local
# (self-hosted Ollama, LM Studio, vLLM on the LAN). Never metadata/link-local, never user:pass@, no query/fragment.
# Host names that RESOLVE to private/link-local addresses are refused for https (DNS rebinding to internal hosts),
# unless the admin lists them in COMSERV_AI_ALLOWED_PRIVATE_HOSTS.
sub validate_base_url {
    my ($class, $u, %o) = @_;
    return (undef, undef) unless defined $u && length($u =~ s/^\s+|\s+$//gr);
    $u =~ s/^\s+|\s+$//g;
    return (undef, 'base URL too long') if length $u > 255;
    my ($scheme, $host, $port, $path) = $u =~ m{^(https?)://([A-Za-z0-9.\-]+|\[[0-9A-Fa-f:]+\])(?::(\d{1,5}))?(/[A-Za-z0-9._~/\-]*)?$}
        or return (undef, 'base URL must look like https://host[:port]/path (no user:pass@, query or fragment)');
    $host = lc $host; (my $bare = $host) =~ s/^\[|\]$//g;
    return (undef, 'port out of range') if defined $port && ($port < 1 || $port > 65535);
    return (undef, 'that address is not allowed') if _is_blocked_ip($bare);
    my $local = ($bare eq 'localhost' || $bare =~ /\.local$/ || _is_private_ip($bare)) ? 1 : 0;
    my %allow = map { (lc($_) => 1) } grep { length } split /[,\s]+/, ($ENV{COMSERV_AI_ALLOWED_PRIVATE_HOSTS} // '');
    if ($scheme eq 'http') {
        return (undef, 'http is only allowed for localhost or a private LAN address; use https') unless $local || $allow{$bare};
    } elsif (!$local && !$allow{$bare}) {
        return (undef, 'IP literal base URLs must be private LAN addresses') if $bare =~ /^[\d.]+$/ || $bare =~ /:/;
        return (undef, 'host name needs a dot') unless $bare =~ /\./;
        unless ($o{no_dns}) {
            my $a = inet_aton($bare);
            if ($a) {
                my $ip = join '.', unpack 'C4', $a;
                return (undef, 'that host resolves to an internal address') if _is_private_ip($ip) || _is_blocked_ip($ip);
            }
        }
    }
    $path //= ''; $path =~ s{/+$}{};
    return ("$scheme://$host" . (defined $port ? ":$port" : '') . $path, undef);
}

# validate_form(\%params) -> (\%clean, \@errors). Never puts the key value in an error.
sub validate_form {
    my ($class, $p, %o) = @_;
    my @e; my %v;
    my $svc = ($p->{service} // '') eq 'other' ? $p->{service_other} : $p->{service};
    $v{service} = $class->normalize_service($svc);
    push @e, 'Provider name must be 2-64 characters: a-z, 0-9, _ . -' unless $class->valid_service($v{service});
    $v{key_type} = lc($p->{key_type} // 'chat'); $v{key_type} =~ s/^\s+|\s+$//g; $v{key_type} = 'chat' unless length $v{key_type};
    push @e, 'Key type must be 2-32 characters: a-z, 0-9, _ -' unless $class->valid_key_type($v{key_type});
    my ($url, $why) = $class->validate_base_url($p->{base_url}, %o);
    push @e, "Base URL: $why" if $why;
    $v{base_url} = $url;
    my $label = $p->{label} // ''; $label =~ s/[\x00-\x1f\x7f]//g; $label =~ s/^\s+|\s+$//g;
    push @e, 'Label is limited to 128 characters' if length $label > 128;
    $v{label} = length $label ? $label : undef;
    my $k = $p->{api_key} // ''; $k =~ s/^\s+|\s+$//g;
    push @e, 'API key is required' if !$o{editing} && !length $k;
    push @e, 'API key looks wrong (too long or has spaces)' if length $k && (length $k > 4096 || $k =~ /\s/);
    $v{api_key} = length $k ? $k : undef;
    return (\%v, \@e);
}

# ---- columns probe (new columns exist only after the migration) ----
my %PROBE;
sub v2_columns_present {
    my ($class, $schema) = @_;
    return 0 unless $schema;
    my $k = ref($schema) || "$schema";
    my $p = $PROBE{$k};
    return $p->{ok} if $p && time - $p->{at} < 300;
    my $ok = eval { $schema->resultset('UserApiKeys')->search({}, { columns => [qw(id key_type base_url label)], rows => 1 })->first; 1 } ? 1 : 0;
    $PROBE{$k} = { ok => $ok, at => time };
    return $ok;
}
sub reset_probe { %PROBE = () }
sub base_columns { qw(id user_id site_id service api_key_encrypted metadata is_active created_at updated_at) }
sub columns_for  { my ($class, $schema) = @_; return [ $class->base_columns, ($class->v2_columns_present($schema) ? qw(key_type base_url label) : ()) ] }

# get_user_key($c, $service, key_type => 'chat', user_id => .., site_id => .., schema => .., allow_owner => 1|0)
# -> { key, row_id, scope => user|site|owner, key_owner => user|site|owner, base_url, service, key_type } or { key => undef, why }
# Precedence: the caller's own active row -> a row for this site -> the owner/system row (allow_owner; the caller decides
# from the existing guest/system policy). key_type: rows without a key_type (pre-migration) count as 'chat'.
sub get_user_key {
    my ($class, $c, $service, %o) = @_;
    $service = $class->normalize_service($service);
    return { key => undef, why => 'bad_service' } unless $class->valid_service($service);
    my $type = $o{key_type} // 'chat';
    my $schema = $o{schema} || eval { $c->model('DBEncy')->schema } or return { key => undef, why => 'db_unavailable' };
    my $v2 = $class->v2_columns_present($schema);
    my $rs = $schema->resultset('UserApiKeys');
    my %base = (service => $service, is_active => '1');
    return { key => undef, why => 'no_key_type_column' } if !$v2 && $type ne 'chat';
    # key_type variants as plain equality searches (chat also matches pre-migration NULL rows)
    my @kt = !$v2 ? ({}) : $type eq 'chat' ? ({ key_type => 'chat' }, { key_type => undef }) : ({ key_type => $type });
    my %attr = (columns => $class->columns_for($schema), order_by => { -desc => 'updated_at' }, rows => 1);
    my $uid = exists $o{user_id} ? $o{user_id} : eval { $c->session->{user_id} };
    my $sid = exists $o{site_id} ? $o{site_id} : (eval { $c->stash->{site_id} } // eval { $c->session->{site_id} });
    my $owner = $class->owner_user_id;
    my @tries;
    for my $k (@kt) { push @tries, [ user  => { %base, %$k, user_id => $uid } ] if defined $uid }
    for my $k (@kt) { push @tries, [ site  => { %base, %$k, site_id => $sid, user_id => $owner } ] if defined $sid }
    for my $k (@kt) { push @tries, [ owner => { %base, %$k, site_id => undef, user_id => $owner } ] if $o{allow_owner} }
    return { tries => \@tries, rs => $rs, attr => \%attr, v2 => $v2, owner => $owner, service => $service, type => $type } if $o{_plan};
    my $why = 'no_row';
    for my $t (@tries) {
        my $row = eval { $rs->search($t->[1], \%attr)->first };
        if ($@) { $why = 'db_unavailable'; last }
        next unless $row && $row->api_key_encrypted;
        my $k = eval { $row->get_api_key };
        unless (defined $k && length $k) { $why = 'decrypt_failed'; next }
        my $scope = $t->[0];
        my $ru = eval { $row->user_id } // $t->[1]{user_id};
        $scope = 'owner' if $scope eq 'user' && defined $ru && $ru == $owner;   # Shanta's own key = shared caps
        return { key => $k, row_id => scalar(eval { $row->id }), scope => $t->[0], key_owner => $scope, service => $service,
                 key_type => $type, base_url => ($v2 ? scalar(eval { $row->get_column('base_url') }) : undef), user_id => $ru };
    }
    return { key => undef, why => $why };
}

# find_row($c, $service, %o) -> ($row, $scope) with the same precedence as get_user_key, no decrypt. Dies on a DB error
# (ApiKeyResolver retries). For callers that need the DBIx row.
sub find_row {
    my ($class, $c, $service, %o) = @_;
    my $plan = $class->get_user_key($c, $service, %o, _plan => 1);
    return () unless $plan->{tries};
    for my $t (@{ $plan->{tries} }) {
        my $row = $plan->{rs}->search($t->[1], $plan->{attr})->first or next;
        my $ru = eval { $row->user_id } // $t->[1]{user_id};
        my $scope = $t->[0] eq 'owner' ? 'global' : $t->[0];
        $scope = 'user' if $t->[0] eq 'user';
        return ($row, $scope);
    }
    return ();
}

# Usage tags for a resolved key: a user's own key bills to that user and stays OUT of the owner's shared caps.
sub usage_tags {
    my ($class, $r) = @_;
    return {} unless ref $r eq 'HASH' && $r->{key};
    my $own = ($r->{key_owner} // '') eq 'user' ? 1 : 0;
    return { key_owner => ($own ? 'user' : ($r->{key_owner} // 'owner')), key_row_id => $r->{row_id},
             ($own ? (billing_status => 'user_key', bill_to_user_id => $r->{user_id}) : ()) };
}

1;
