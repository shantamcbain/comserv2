use strict;
use warnings;
use Test::More;

BEGIN { use_ok 'Comserv::Controller::AI' }

can_ok('Comserv::Controller::AI', 'get_file_index');
can_ok('Comserv::Controller::AI', 'rebuild_file_index');
can_ok('Comserv::Controller::AI', 'add_to_index');
can_ok('Comserv::Controller::AI', 'remove_from_index');
can_ok('Comserv::Controller::AI', 'create_file');
can_ok('Comserv::Controller::AI', 'delete_file');

{
    my $controller = bless {}, 'Comserv::Controller::AI';
    
    ok($controller->can('get_file_index'), 'get_file_index method is available');
    ok($controller->can('rebuild_file_index'), 'rebuild_file_index method is available');
    ok($controller->can('add_to_index'), 'add_to_index method is available');
    ok($controller->can('remove_from_index'), 'remove_from_index method is available');
    ok($controller->can('create_file'), 'create_file method is available');
    ok($controller->can('delete_file'), 'delete_file method is available');
}

done_testing();
