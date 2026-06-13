use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

BEGIN {
    use_ok('Comserv::Util::Logging')
        or BAIL_OUT('Failed to load Comserv::Util::Logging');
}

subtest 'unwraps Catalyst exception into controller::action label' => sub {
    my $msg = 'Unhandled application error: Caught exception in '
        . 'Comserv::Controller::CloudflareAPI->dns_records '
        . q{"Can't call method "email" on an undefined value at CloudflareAPI.pm line 314."};
    my $meta = Comserv::Util::Logging::error_audit_meta('end', 'Root.pm', 2126, $msg, undef);

    is($meta->{controller_action}, 'CloudflareAPI::dns_records', 'controller::action extracted');
    like($meta->{subject}, qr/\[Error\] CloudflareAPI::dns_records/, 'subject names real area');
    like($meta->{subject}, qr/Can't call method/, 'subject includes error hint');
    like($meta->{fingerprint}, qr/^cloudflareapi::dns_records\|/, 'fingerprint keyed by area');
};

subtest 'global_error_handler message gets same fingerprint as end wrapper' => sub {
    my $inner = q{Caught exception in Comserv::Controller::Planning->daily "Not a HASH reference"};
    my $global = "[GLOBAL ERROR] Unhandled exception: $inner";
    my $end    = "Unhandled application error: $inner";

    my $m1 = Comserv::Util::Logging::error_audit_meta('global_error_handler', 'Comserv.pm', 237, $global, undef);
    my $m2 = Comserv::Util::Logging::error_audit_meta('end', 'Root.pm', 2221, $end, undef);

    is($m1->{fingerprint}, $m2->{fingerprint}, 'duplicate log paths share fingerprint');
    is($m1->{controller_action}, 'Planning::daily', 'planning daily identified');
};

subtest 'meaningful subroutine kept when no Catalyst wrapper' => sub {
    my $meta = Comserv::Util::Logging::error_audit_meta(
        'modify_todo', 'Comserv/Controller/Todo.pm', 100,
        'Validation failed: due_date required', undef
    );
    like($meta->{subject}, qr/\[Error\] Todo::modify_todo/, 'uses file + subroutine');
};

done_testing;