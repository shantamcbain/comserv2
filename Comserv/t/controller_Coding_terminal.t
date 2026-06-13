use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use JSON;

BEGIN {
    use_ok('Comserv::Controller::Coding') or BAIL_OUT('Failed to load Coding controller');
    use_ok('Comserv::Util::CodingAccess') or BAIL_OUT('Failed to load CodingAccess');
}

my $ctrl = bless {}, 'Comserv::Controller::Coding';

{
    package MockResponse;
    sub new { bless {}, shift }
    sub content_type { my ($self, $type) = @_; $self->{content_type} = $type }
    sub body { my ($self, $body) = @_; $self->{body} = $body }
    sub status { my ($self, $status) = @_; $self->{status} = $status }

    package MockURI;
    sub new {
        my ($class, %opts) = @_;
        bless { host => $opts{host} // '172.30.131.126' }, $class;
    }
    sub host { shift->{host} }

    package MockRequest;
    sub new {
        my ($class, %opts) = @_;
        bless { params => {}, host => $opts{host} // '172.30.131.126' }, $class;
    }
    sub params { shift->{params} }
    sub uri {
        my $self = shift;
        MockURI->new($self->{host});
    }

    package MockReqAccessor;
    sub new {
        my ($class, $host) = @_;
        bless { host => $host }, $class;
    }
    sub uri {
        my $self = shift;
        MockURI->new(host => $self->{host});
    }

    package MockContext;
    sub new {
        my ($class, %opts) = @_;
        bless {
            res     => MockResponse->new,
            req     => MockRequest->new(host => ($opts{host} // '172.30.131.126')),
            session => { username => ($opts{username} // 'shanta') },
        }, $class;
    }
    sub response { shift->{res} }
    sub request  { shift->{req} }
    sub session  { shift->{session} }
    sub req {
        my $self = shift;
        MockReqAccessor->new($self->{req}->{host});
    }
    sub controller { undef }
}

ok(Comserv::Util::CodingAccess::workstation_allowed(
    MockContext->new(username => 'shanta', host => '172.30.131.126')
), 'shanta on workstation IP allowed');

ok(Comserv::Util::CodingAccess::workstation_allowed(
    MockContext->new(username => 'shanta', host => 'localhost')
), 'localhost allowed for shanta on same workstation');

ok(!Comserv::Util::CodingAccess::workstation_allowed(
    MockContext->new(username => 'other', host => '172.30.131.126')
), 'non-shanta blocked');

{
    my $c = MockContext->new();
    $ctrl->terminal_status($c);
    my $body = decode_json($c->response->{body});
    is($body->{success}, 1);
    is($body->{allowed}, 1);
    is($body->{terminal_ws_path}, '/coding/terminal_ws');
}

{
    my $c = MockContext->new(host => 'localhost');
    $ctrl->terminal_status($c);
    my $body = decode_json($c->response->{body});
    is($body->{allowed}, 1, 'localhost allowed for shanta on workstation');
}

{
    my $c = MockContext->new();
    $ctrl->run_command($c);
    my $body = decode_json($c->response->{body});
    is($body->{success}, 0);
    like($body->{error}, qr/Command is required/);
}

done_testing();