use strict;
use warnings;
use Test::More;

BEGIN { use_ok 'Comserv::Controller::AI' }

can_ok('Comserv::Controller::AI', 'models');
can_ok('Comserv::Controller::AI', 'auto_sync_models');

{
    my $controller = bless {}, 'Comserv::Controller::AI';
    
    ok($controller->can('models'), 'models method is available');
    ok($controller->can('auto_sync_models'), 'auto_sync_models method is available');
}

# Test AI controller loads without errors
{
    my $controller_loaded;
    eval {
        require Comserv::Controller::AI;
        $controller_loaded = 1;
    };
    
    ok($controller_loaded && !$@, 'AI controller loads without compilation errors')
        or diag("Compilation error: $@");
}

done_testing();