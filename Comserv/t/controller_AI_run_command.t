use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use JSON;

BEGIN {
    use_ok('Comserv::Controller::AI') or BAIL_OUT("Failed to load AI controller");
}

my $ctrl = bless {}, 'Comserv::Controller::AI';

{
    package MockResponse;
    sub new { bless {}, shift }
    sub content_type { my ($self, $type) = @_; $self->{content_type} = $type }
    sub body { my ($self, $body) = @_; $self->{body} = $body }

    package MockRequest;
    sub new { bless { params => {} }, shift }
    sub params { shift->{params} }

    package MockConfig;
    sub new { bless {}, shift }

    package MockContext;
    sub new {
        my ($class, %opts) = @_;
        bless {
            res => MockResponse->new,
            req => MockRequest->new,
            config => \%opts,
        }, $class;
    }
    sub response { shift->{res} }
    sub request { shift->{req} }
    sub config { shift->{config} }
}

{
    no warnings 'redefine';
    local *Comserv::Controller::AI::_editor_enabled = sub { 0 };

    my $c = MockContext->new();
    $ctrl->run_command($c);

    my $res_body = decode_json($c->response->{body});
    is($res_body->{success}, 0);
    like($res_body->{error}, qr/Admin only/);
}

{
    no warnings 'redefine';
    local *Comserv::Controller::AI::_editor_enabled = sub { 1 };

    my $c = MockContext->new();
    $ctrl->run_command($c);

    my $res_body = decode_json($c->response->{body});
    is($res_body->{success}, 0);
    like($res_body->{error}, qr/Command is required/);
}

{
    no warnings 'redefine';
    local *Comserv::Controller::AI::_editor_enabled = sub { 1 };

    my $c = MockContext->new();
    $c->request->{params}->{command} = 'rm -rf /';
    $ctrl->run_command($c);

    my $res_body = decode_json($c->response->{body});
    is($res_body->{success}, 0);
    like($res_body->{error}, qr/Command blocked for safety/);
}

{
    no warnings 'redefine';
    local *Comserv::Controller::AI::_editor_enabled = sub { 1 };
    local *Comserv::Controller::AI::_project_root_path = sub { "." };
    local *Comserv::Controller::AI::_grok_cli_api_key = sub { "fake_key" };
    local *Comserv::Controller::AI::_grok_home = sub { "/tmp" };

    my $c = MockContext->new();
    $c->request->{params}->{command} = 'echo "hello from test"';
    $ctrl->run_command($c);

    my $res_body = decode_json($c->response->{body});
    is($res_body->{success}, 1);
    like($res_body->{output}, qr/hello from test/);
    is($res_body->{exit_code}, 0);
}

done_testing();
