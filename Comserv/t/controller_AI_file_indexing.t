use strict;
use warnings;
use Test::More;

BEGIN { use_ok 'Comserv::Controller::AI' }

can_ok('Comserv::Controller::AI', 'get_file_index');
can_ok('Comserv::Controller::AI', 'search_files');
can_ok('Comserv::Controller::AI', 'resolve_route');
can_ok('Comserv::Controller::AI', 'rebuild_file_index');
can_ok('Comserv::Controller::AI', 'add_to_index');
can_ok('Comserv::Controller::AI', 'remove_from_index');
can_ok('Comserv::Controller::AI', 'create_file');
can_ok('Comserv::Controller::AI', 'delete_file');
can_ok('Comserv::Controller::AI', 'quick_chat');
can_ok('Comserv::Controller::AI', 'editor_config');

{
    my $controller = bless {}, 'Comserv::Controller::AI';
    
    ok($controller->can('get_file_index'), 'get_file_index method is available');
    ok($controller->can('search_files'), 'search_files method is available');
    ok($controller->can('resolve_route'), 'resolve_route method is available');
    ok($controller->can('rebuild_file_index'), 'rebuild_file_index method is available');
    ok($controller->can('add_to_index'), 'add_to_index method is available');
    ok($controller->can('remove_from_index'), 'remove_from_index method is available');
    ok($controller->can('create_file'), 'create_file method is available');
    ok($controller->can('delete_file'), 'delete_file method is available');
    ok($controller->can('quick_chat'), 'quick_chat method is available');
    ok($controller->can('_ollama_hosts_to_probe'), '_ollama_hosts_to_probe is available');
    ok($controller->can('_ollama_chat_with_failover'), '_ollama_chat_with_failover is available');
    ok($controller->can('_find_reachable_ollama_host'), '_find_reachable_ollama_host is available');
    ok($controller->can('_is_member_or_above'), '_is_member_or_above is available');
    ok($controller->can('_is_lightweight_ollama_request'), '_is_lightweight_ollama_request is available');
}

{
    my $controller = bless {}, 'Comserv::Controller::AI';
    ok($controller->_is_lightweight_ollama_request('helpdesk', 'How do I submit a ticket?'),
        'helpdesk agent is lightweight');
    ok($controller->_is_lightweight_ollama_request('general', 'take me to HelpDesk'),
        'navigation prompt is lightweight');
    ok(!$controller->_is_lightweight_ollama_request('planning', 'audit all project names'),
        'planning audit is not lightweight');
}

{
    my $controller = bless {}, 'Comserv::Controller::AI';
    my $cfg = {
        Ollama => { host => '192.168.1.199', fallback_host => '192.168.1.199', port => 11434 },
        aew_ssh_host => '172.30.131.126',
    };
    {
        no warnings 'redefine';
        *MockC::config = sub { $_[0] };
    }
    my $mock_c = bless $cfg, 'MockC';
    local $ENV{COMSERV_DEV_MODE} = 1;
    my @hosts = $controller->_ollama_hosts_to_probe($mock_c);
    ok(@hosts >= 3, 'ollama host probe list has multiple candidates');
    ok($hosts[0] eq '127.0.0.1', 'dev workstation probes localhost first');
    ok((grep { $_ eq '192.168.1.199' } @hosts), 'config primary host remains in probe list');
}

done_testing();
