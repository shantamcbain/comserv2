use strict;
use warnings;
use Test::More;

BEGIN { use_ok 'Comserv::Controller::AI' }

# Test that models method exists in the AI controller
can_ok('Comserv::Controller::AI', 'models');

# Test method signature and basic functionality
{
    my $controller = bless {}, 'Comserv::Controller::AI';
    
    # Test that the method can be called (basic check)
    ok($controller->can('models'), 'models method is available');
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