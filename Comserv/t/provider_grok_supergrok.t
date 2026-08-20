use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Temp qw(tempdir);
use File::Spec;
use JSON qw(encode_json);

BEGIN { use_ok 'Comserv::Model::AI2::Provider::Grok' }

my $g = Comserv::Model::AI2::Provider::Grok->new;
ok($g, 'Grok provider instantiates');

subtest 'token reader — missing file' => sub {
    is(Comserv::Model::AI2::Provider::Grok::_supergrok_oauth_token_from_file('/no/such/file'),
       undef, 'missing file is undef');
};

subtest 'token reader — hermes auth.json shape' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $path = File::Spec->catfile($dir, 'auth.json');
    {
        open my $fh, '>', $path or die $!;
        print $fh encode_json({
            providers => {
                'xai-oauth' => {
                    tokens => { access_token => 'sg-test-token-not-real' },
                },
            },
        });
        close $fh;
    }
    is(Comserv::Model::AI2::Provider::Grok::_supergrok_oauth_token_from_file($path),
       'sg-test-token-not-real', 'reads providers.xai-oauth.tokens.access_token');
};

subtest 'portable secret file wins over nothing' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $sec = File::Spec->catfile($dir, 'supergrok_oauth');
    {
        open my $fh, '>', $sec or die $!;
        print $fh "  portable-token  \n";
        close $fh;
    }
    local $ENV{COMSERV_SECRETS_DIR} = $dir;
    local $ENV{COMSERV_HERMES_AUTH_JSON} = File::Spec->catfile($dir, 'missing-auth.json');
    local $ENV{SUPERGROK_OAUTH_TOKEN} = undef;
    local $ENV{XAI_OAUTH_TOKEN} = undef;
    local $ENV{GROK_API_KEY} = undef;
    local $ENV{XAI_API_KEY} = undef;
    # Point HOME at empty dir so ~/.comserv/secrets and ~/.hermes/auth.json miss.
    local $ENV{HOME} = $dir;
    local $ENV{HERMES_HOME} = $dir;
    my $key = $g->resolve_prepaid_key(undef);
    is($key, 'portable-token', 'reads trimmed token from COMSERV_SECRETS_DIR/supergrok_oauth');
    ok($g->is_prepaid_source, 'portable file is prepaid');
    is($g->credential_source, 'supergrok_file', 'source is supergrok_file');
};

subtest 'fallback catalog pins grok-4.6' => sub {
    $g->{_last_cred_source} = 'supergrok_file';
    my @m = $g->_label_models(qw(grok-4.3 grok-4.6 grok-imagine-image grok-build-0.1));
    is($m[0]{id}, 'grok-4.6', 'grok-4.6 pinned first');
    ok((!grep { $_->{id} =~ /imagine-image/ } @m), 'image models excluded from chat list');
    like($m[0]{label}, qr/^SuperGrok:/, 'prepaid label');
};

subtest 'detect_provider routes SuperGrok wire format' => sub {
    require Comserv::Model::AI2::Router;
    my $r = Comserv::Model::AI2::Router->new;
    my ($p, $m) = $r->_detect_provider('supergrok|grok-4.6');
    is($p, 'supergrok', 'supergrok|slug stays SuperGrok (not xAI)');
    is($m, 'grok-4.6', 'bare slug after prefix strip');
};

done_testing();
