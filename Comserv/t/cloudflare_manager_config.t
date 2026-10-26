#!/usr/bin/env perl
# CloudflareManager credential loading: placeholder values in the repo config
# files must never override a real token from the shared secrets file, and the
# cache-rules page must load the same token the DNS pages do.
# Uses temporary dirs and fake token text only; no real credentials, no network.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::MaybeXS qw(encode_json);
use HTTP::Response;

use_ok('Comserv::Util::CloudflareManager');
use_ok('Comserv::Util::CloudflareCache');

my $REAL = 'FAKEREALTOKEN_0123456789abcdefghijklmnopqrstuv';

{ package QuietLog; sub new { bless {}, shift } sub AUTOLOAD { 1 } sub DESTROY {} }

sub write_json { my ($path, $data) = @_; my ($dir) = $path =~ m{^(.*)/}; make_path($dir); open my $fh, '>', $path or die $!; print $fh encode_json($data); close $fh }

sub config_for {
    my (%o) = @_;
    my $home    = tempdir(CLEANUP => 1);
    my $secrets = tempdir(CLEANUP => 1);
    local $ENV{CATALYST_HOME}         = $home;
    local $ENV{COMSERV_SECRETS_DIR}   = $secrets;
    local $ENV{CLOUDFLARE_API_TOKEN}  = $o{env_token} // '';
    local $ENV{CF_API_TOKEN}          = '';
    write_json("$secrets/cloudflare.json", { cloudflare => { api_token => $o{secret_token}, email => 'a@example.com' } }) if defined $o{secret_token};
    write_json("$home/root/config/api/cloudflare_config.json", { cloudflare => { api_token => $o{repo_token}, email => 'repo@example.com', application_id => 'app1', domains => { 'one.example' => { zone_id => 'z1' }, 'two.example' => { zone_id => 'z2' } } } }) if exists $o{repo_token};
    write_json("$home/config/api_credentials.json", { cloudflare => { api_token => $o{creds_token}, email => 'c@example.com' } }) if exists $o{creds_token};
    my $cm = Comserv::Util::CloudflareManager->new(logger => QuietLog->new);
    return ($cm->config, $cm);
}

my @placeholders = ('[% ENV.CLOUDFLARE_API_TOKEN %]', '<replace-with-cloudflare-api-token>', 'YOUR_TOKEN_HERE', 'your-token', 'changeme', 'placeholder', 'xxxxxxxx', '', '   ');
for my $ph (@placeholders) {
    my ($cfg) = config_for(secret_token => $REAL, repo_token => $ph);
    is($cfg->{cloudflare}{api_token}, $REAL, "placeholder in repo config ('$ph') does not override the real secrets-file token");
    is($cfg->{cloudflare}{application_id}, 'app1', 'non-secret repo values still merged');
    ok(ref $cfg->{cloudflare}{domains} eq 'HASH', 'domains still merged');
}

{
    my ($cfg) = config_for(secret_token => $REAL, creds_token => 'YOUR_TOKEN');
    is($cfg->{cloudflare}{api_token}, $REAL, 'placeholder in api_credentials.json does not wipe the real token either');
}
{
    my ($cfg) = config_for(secret_token => $REAL, repo_token => 'real-looking-but-lower-priority-ABCDEFGHIJKLMNOP');
    isnt($cfg->{cloudflare}{api_token}, '', 'a non-placeholder value from the later file keeps previous behaviour (later file wins)');
}
{
    my ($cfg) = config_for(repo_token => '[% ENV.CLOUDFLARE_API_TOKEN %]', env_token => $REAL);
    is($cfg->{cloudflare}{api_token}, $REAL, 'no secrets file: env var supplies the token when the repo file only has a placeholder');
}
{
    my ($cfg) = config_for(repo_token => 'YOUR_TOKEN');
    ok(!$cfg->{cloudflare}{api_token}, 'placeholder alone is never used as a token');
}
is(Comserv::Util::CloudflareManager::_is_placeholder($_), 1, "_is_placeholder: " . (defined $_ ? "'$_'" : 'undef')) for (undef, '', 'YOUR_X', 'Your token', 'ChangeMe', '<x>', 'XXX', '[% a %]');
is(Comserv::Util::CloudflareManager::_is_placeholder($REAL), 0, '_is_placeholder: real-looking token is not a placeholder');

# The cache page loads the same credential as DNS (same _get_api_credentials path)
{
    my ($cfg, $cm) = config_for(secret_token => $REAL, repo_token => '[% ENV.CLOUDFLARE_API_TOKEN %]');
    my $seen;
    my $http = bless {}, 'CaptureHTTP';
    { package CaptureHTTP; sub request { my ($s, $req) = @_; $main::seen_auth = $req->header('Authorization'); HTTP::Response->new(200, 'OK', [], '{"success":true,"errors":[],"result":{"status":"active"}}') } }
    my $home    = tempdir(CLEANUP => 1);
    my $secrets = tempdir(CLEANUP => 1);
    write_json("$secrets/cloudflare.json", { cloudflare => { api_token => $REAL } });
    write_json("$home/root/config/api/cloudflare_config.json", { cloudflare => { api_token => '[% ENV.CLOUDFLARE_API_TOKEN %]', domains => { 'one.example' => { zone_id => 'z1' }, 'two.example' => { zone_id => 'z2' } } } });
    local $ENV{CATALYST_HOME} = $home; local $ENV{COMSERV_SECRETS_DIR} = $secrets; local $ENV{CLOUDFLARE_API_TOKEN} = '';
    my ($cf, $err) = Comserv::Util::CloudflareCache->from_app_credentials(http => $http, export_dir => $home);
    ok($cf, 'CloudflareCache builds from the shared credential loader') or diag $err;
    $cf->verify_token;
    is($main::seen_auth, "Bearer $REAL", 'CloudflareCache sends the same real token DNS would use (not the placeholder)');
    my $known = Comserv::Util::CloudflareCache->known_domains;
    is_deeply([ map { $_->{name} } @$known ], [ 'one.example', 'two.example' ], 'known_domains reads the config domains (fallback labels only)');
}

done_testing();
