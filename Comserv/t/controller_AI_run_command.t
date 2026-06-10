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
    sub status { my ($self, $status) = @_; $self->{status} = $status }

    package MockURI;
    sub new { bless {}, shift }
    sub host { 'localhost' }
    sub port { 3001 }

    package MockRequest;
    sub new { bless { params => {}, body_params => {} }, shift }
    sub params { shift->{params} }
    sub body_parameters { shift->{body_params} }
    sub param {
        my ($self, $name) = @_;
        return $self->{params}->{$name} // $self->{body_params}->{$name};
    }
    sub uri { MockURI->new }

    package MockConfig;
    sub new { bless {}, shift }

    package MockContext;
    sub new {
        my ($class, %opts) = @_;
        bless {
            res => MockResponse->new,
            req => MockRequest->new,
            config => \%opts,
            session => { username => 'Shanta', roles => ['admin'] },
        }, $class;
    }
    sub response { shift->{res} }
    sub request { shift->{req} }
    sub config { shift->{config} }
    sub session { shift->{session} }
}

{
    package Comserv::Controller::AI;
    no warnings 'redefine';
    sub logging {
        my $self = shift;
        return bless {}, 'MockLogging';
    }
}

{
    package MockLogging;
    sub log_with_details { 1 }
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

# --- Test Path Allowance ---
{
    is($ctrl->_editor_path_allowed('lib/Comserv/Controller/AI.pm'), 'lib/Comserv/Controller/AI.pm', 'lib/ path allowed');
    is($ctrl->_editor_path_allowed('secrets/db.json'), 0, 'secrets/ path blocked');
    is($ctrl->_editor_path_allowed('.git/config'), 0, '.git/ path blocked');
    is($ctrl->_editor_path_allowed('local/lib/perl5'), 0, 'local/ path blocked');
    is($ctrl->_editor_path_allowed('Comserv/lib/Comserv/Controller/AI.pm'), 'lib/Comserv/Controller/AI.pm', 'Comserv/ prefix removed and allowed');
}

# --- Test list_dir ---
{
    no warnings 'redefine';
    local *Comserv::Controller::AI::_editor_enabled = sub { 1 };
    local *Comserv::Controller::AI::_project_root_path = sub { "./Comserv" };

    my $c = MockContext->new();
    $ctrl->list_dir($c);

    my $res_body = decode_json($c->response->{body});
    is($res_body->{success}, 1, 'list_dir success');
    ok(exists $res_body->{entries}, 'list_dir returns entries');
    my @paths = map { $_->{path} } @{$res_body->{entries}};
    ok((grep { $_ eq 'lib' } @paths), 'lib folder found in root');
}

# --- Test read_file ---
{
    no warnings 'redefine';
    local *Comserv::Controller::AI::_editor_enabled = sub { 1 };
    local *Comserv::Controller::AI::_project_root_path = sub { "./Comserv" };

    my $c = MockContext->new();
    $c->request->{params}->{path} = 'Comserv/t/controller_AI_models.t';
    $ctrl->read_file($c);

    my $res_body = decode_json($c->response->{body});
    is($res_body->{success}, 1, 'read_file success');
    like($res_body->{content}, qr/done_testing/, 'file content loaded correctly');
}

# --- Test apply_fix and revert_code ---
{
    no warnings 'redefine';
    local *Comserv::Controller::AI::_editor_enabled = sub { 1 };
    local *Comserv::Controller::AI::_project_root_path = sub { "./Comserv" };
    local *Comserv::Controller::AI::_is_shanta_editor = sub { 1 };

    # Create a dummy file for the test
    my $test_file = 'Comserv/t/temp_test_file.txt';
    open(my $fh, '>', $test_file) or die "Cannot create test file: $!";
    print $fh "Original Content\n";
    close $fh;

    my $c = MockContext->new();
    $c->request->{params}->{path} = 't/temp_test_file.txt';
    $c->request->{body_params}->{content} = "Modified Content\n";
    
    $ctrl->apply_fix($c);

    my $res_body = decode_json($c->response->{body});
    is($res_body->{success}, 1, 'apply_fix success');
    is($res_body->{backup}, 't/temp_test_file.txt.bak', 'backup file indicated');

    # Verify backup and content
    ok(-f 'Comserv/t/temp_test_file.txt.bak', 'backup file created on disk');
    
    open(my $rfh, '<', $test_file) or die "Cannot read test file: $!";
    my $content = <$rfh>;
    close $rfh;
    is($content, "Modified Content\n", 'file content was modified');

    # Now revert the change!
    my $c_revert = MockContext->new();
    $ctrl->revert_code($c_revert);

    my $rev_body = decode_json($c_revert->response->{body});
    is($rev_body->{success}, 1, 'revert_code success');
    ok(!-f 'Comserv/t/temp_test_file.txt.bak', 'backup file was deleted');

    open(my $rfh2, '<', $test_file) or die "Cannot read test file: $!";
    my $content2 = <$rfh2>;
    close $rfh2;
    is($content2, "Original Content\n", 'original file content restored');

    # Clean up test file
    unlink $test_file;
}

done_testing();
