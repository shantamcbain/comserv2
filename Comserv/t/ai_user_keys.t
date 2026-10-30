use strict; use warnings; use Test::More;
use FindBin; use lib "$FindBin::Bin/../lib";
use Comserv::Util::AI::UserKeys;
my $UK = 'Comserv::Util::AI::UserKeys';
$ENV{COMSERV_AI_OWNER_USER_ID} = 178;

# --- slug / key_type / enum-free service
ok $UK->valid_service($_), "slug ok: $_" for qw(openrouter grok my-vllm together.ai a_b x9);
ok !$UK->valid_service($_), 'slug bad: ' . ($_ // 'undef') for ('A', 'x', 'Open Router', 'a/b', '<script>', 'a' x 65, '', undef);
is $UK->normalize_service(' XAI '), 'grok', 'xai alias -> grok';
is $UK->normalize_service('Mistral'), 'mistral', 'lowercased';

# --- base URL (SSRF rule)
my @good = ('https://api.example.com/v1', 'http://localhost:11434/v1', 'http://192.168.1.50:8000/v1', 'http://10.0.0.2/v1',
            'http://gpu.local:8080', 'https://api.together.xyz/v1/');
my @bad  = ('http://api.example.com/v1', 'https://169.254.169.254/latest', 'http://169.254.169.254/', 'https://8.8.8.8/v1',
            'ftp://x.com', 'https://user:pw@api.example.com', 'https://api.example.com/v1?x=1', 'https://api.example.com/#f',
            'file:///etc/passwd', 'http://0.0.0.0:80', 'https://intranet', 'gopher://x.com', 'https://100.64.1.1/');
for (@good) { my ($u, $w) = $UK->validate_base_url($_, no_dns => 1); ok $u, "url ok: $_" or diag $w }
for (@bad)  { my ($u, $w) = $UK->validate_base_url($_, no_dns => 1); ok !$u && $w, "url refused: $_" }
is +($UK->validate_base_url('https://api.example.com/v1/', no_dns => 1))[0], 'https://api.example.com/v1', 'trailing slash trimmed';
{ local $ENV{COMSERV_AI_ALLOWED_PRIVATE_HOSTS} = 'vllm.corp';
  ok +($UK->validate_base_url('http://vllm.corp:8000/v1', no_dns => 1))[0], 'admin allow-list host over http'; }

# --- form
my ($v, $e) = $UK->validate_form({ service => 'other', service_other => 'My-VLLM', key_type => 'chat', base_url => 'http://192.168.1.9:8000/v1',
                                   label => "work\x07 key", api_key => join('', 'test', 'only', 'placeholder', '0' x 16) }, no_dns => 1);
is_deeply $e, [], 'other provider form ok';
is $v->{service}, 'my-vllm', 'other slug normalised';
is $v->{label}, 'work key', 'control chars stripped from label';
($v, $e) = $UK->validate_form({ service => 'other', service_other => 'bad slug!', key_type => 'x', base_url => 'http://evil.com', api_key => join('', 'TEST', 'ONLY', 'SECRET') . ' def' }, no_dns => 1);
is scalar(@$e), 4, 'four errors (slug, type, url, key)';
unlike join(' ', @$e), qr/SECRET/, 'errors never echo the key';
($v, $e) = $UK->validate_form({ service => 'grok', key_type => 'management' }, editing => 1);
is_deeply $e, [], 'edit without new key ok';
($v, $e) = $UK->validate_form({ service => 'grok' });
ok grep({ /required/ } @$e), 'new key needs a key';

# --- cost tagging
is_deeply $UK->usage_tags({ key => 'k', key_owner => 'user', row_id => 7, user_id => 42 }),
    { key_owner => 'user', key_row_id => 7, billing_status => 'user_key', bill_to_user_id => 42 }, 'own key bills to user';
is_deeply $UK->usage_tags({ key => 'k', key_owner => 'owner', row_id => 3, user_id => 178 }),
    { key_owner => 'owner', key_row_id => 3 }, 'owner key stays on the shared caps';
is_deeply $UK->usage_tags({ key => undef }), {}, 'no key, no tags';

# --- lookup precedence against an in-memory DB (enum-free service, key_type, own > site > owner)
SKIP: {
    skip 'DBD::SQLite missing', 16 unless eval { require DBD::SQLite; 1 };
    require Comserv::Model::Schema::Ency;
    my $s = Comserv::Model::Schema::Ency->connect('dbi:SQLite:dbname=:memory:', '', '', { RaiseError => 1, PrintError => 0 });
    $s->storage->dbh->do(q{CREATE TABLE user_api_keys (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INT NOT NULL, site_id INT,
        service VARCHAR(64) NOT NULL, key_type VARCHAR(32) DEFAULT 'chat', base_url VARCHAR(255), label VARCHAR(128),
        api_key_encrypted TEXT NOT NULL, metadata TEXT, is_active VARCHAR(1) NOT NULL DEFAULT '1',
        created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        UNIQUE (user_id, site_id, service, key_type))});
    $UK->reset_probe;
    my $rs = $s->resultset('UserApiKeys');
    my $enc = sub { $rs->new({})->encrypt_api_key($_[0]) };
    my $t = 0; my $mk = sub { my %r = @_; my $k = delete $r{k}; $rs->create({ is_active => '1', updated_at => '2026-10-30 00:00:' . sprintf('%02d', $t++), %r, api_key_encrypted => $enc->($k) }) };
    $mk->(user_id => 178, service => 'openrouter', k => 'OWNER-OR');                   # owner / system
    $mk->(user_id => 178, site_id => 5, service => 'openrouter', k => 'SITE-OR');      # site key (owner's)
    $mk->(user_id => 42,  service => 'openrouter', k => 'USER42-OR');                  # user 42 own
    $mk->(user_id => 99,  service => 'openrouter', k => 'USER99-OR');                  # another user, site NULL: must never serve others
    $mk->(user_id => 42,  service => 'my-vllm', base_url => 'http://192.168.1.9:8000/v1', k => 'VLLM');
    $mk->(user_id => 178, service => 'grok', key_type => 'management', k => 'XAI-MGMT');
    ok $UK->v2_columns_present($s), 'v2 columns probe';
    my $g = sub { $UK->get_user_key(undef, $_[0], schema => $s, user_id => $_[1], site_id => $_[2], @_[3 .. $#_]) };
    is $g->('openrouter', 42, 5)->{key}, 'USER42-OR', 'own key first';
    is $g->('openrouter', 42, 5)->{key_owner}, 'user', 'own key -> key_owner user';
    is $g->('openrouter', 7, 5)->{key}, 'SITE-OR', 'no own key -> site key';
    is $g->('openrouter', 7, undef)->{key}, undef, 'no owner fallback unless allowed';
    is $g->('openrouter', 7, undef, allow_owner => 1)->{key}, 'OWNER-OR', 'owner key when policy allows';
    is $g->('openrouter', 7, undef, allow_owner => 1)->{key_owner}, 'owner', 'owner key -> shared caps';
    isnt $g->('openrouter', 7, undef, allow_owner => 1)->{key}, 'USER99-OR', "another user's key never used";
    is $g->('openrouter', 178, undef)->{key_owner}, 'owner', "Shanta's own row counts as owner";
    is $g->('my-vllm', 42, undef)->{base_url}, 'http://192.168.1.9:8000/v1', 'custom provider + base_url';
    is $g->('grok', 7, undef, allow_owner => 1)->{key}, undef, 'management key is not a chat key';
    is $g->('xai', 7, undef, allow_owner => 1, key_type => 'management')->{key}, 'XAI-MGMT', 'management key by type (xai alias)';
    $mk->(user_id => 42, service => 'grok', key_type => 'chat', k => 'G1');
    ok eval { $mk->(user_id => 42, service => 'grok', key_type => 'management', k => 'G2'); 1 }, 'same service, other key_type allowed';

    # XaiBilling stub: no key -> no-op; key but not enabled -> no network
    require Comserv::Util::AI::XaiBilling;
    is +(Comserv::Util::AI::XaiBilling->usage(undef, key_result => { key => undef }))->{why}, 'no_management_key', 'xai billing no-key no-op';
    is +(Comserv::Util::AI::XaiBilling->usage(undef, key_result => { key => 'x' }))->{why}, 'not_enabled', 'xai billing not called';
}

# --- OpenAI-compatible provider with a fake UA (no network); key only in the header
{
    package FakeUA; sub new { bless { seen => [] }, shift }
    sub post { my ($s, $url, %h) = @_; push @{ $s->{seen} }, [ $url, \%h ];
        require HTTP::Response; my $r = HTTP::Response->new(200); $r->content('{"model":"m1","choices":[{"message":{"content":"hi"}}],"usage":{"prompt_tokens":3,"completion_tokens":1}}'); $r }
}
require Comserv::Model::AI2::Provider::OpenAICompatible;
my $ua = FakeUA->new;
my $r = Comserv::Model::AI2::Provider::OpenAICompatible->new->chat(base_url => 'http://192.168.1.9:8000/v1', api_key => 'K-SECRET',
    model => 'qwen/any-model:7b', messages => [{ role => 'user', content => 'hi' }], ua => $ua, no_dns => 1);
ok $r->{success}, 'generic call ok';
is $ua->{seen}[0][0], 'http://192.168.1.9:8000/v1/chat/completions', 'posts to base_url/chat/completions';
is $ua->{seen}[0][1]{Authorization}, 'Bearer K-SECRET', 'key in header';
unlike $ua->{seen}[0][1]{Content}, qr/K-SECRET/, 'key not in body';
$r = Comserv::Model::AI2::Provider::OpenAICompatible->new->chat(base_url => 'http://169.254.169.254', api_key => 'K', model => 'm', messages => [{}], ua => $ua);
ok !$r->{success} && $r->{error} =~ /refused/, 'metadata address refused at call time';
$r = Comserv::Model::AI2::Provider::OpenAICompatible->new->chat(base_url => 'https://api.example.com/v1', api_key => 'K', model => 'bad model id', messages => [{}], ua => $ua, no_dns => 1);
ok !$r->{success}, 'bad model id refused';

done_testing;
