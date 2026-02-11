#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;
use Test::Exception;
use File::Temp qw(tempdir);
use Path::Tiny;
use JSON::MaybeXS;

use FindBin;
use lib "$FindBin::Bin/../../lib";

use_ok('Comserv::Middleware::ApiDomainDetector');

my $tempdir = tempdir(CLEANUP => 1);
my $config_path = path($tempdir, 'api_domains.json');

my $test_config = {
    environments => {
        development => {
            external_domain => 'api.workstation.local',
            local_domains => ['*.local', 'localhost', '127.0.0.1'],
            require_https => 0,
            local_bypass_enabled => 1
        },
        production => {
            external_domain => 'api.computersystemconsulting.ca',
            local_domains => [],
            require_https => 1,
            local_bypass_enabled => 0
        }
    },
    current_environment => 'development'
};

$config_path->spew_utf8(encode_json($test_config));

my $middleware = Comserv::Middleware::ApiDomainDetector->new(
    config_path => $config_path->stringify,
    app => sub { 
        my $env = shift;
        return [200, ['Content-Type' => 'text/plain'], ['OK']];
    }
);

isa_ok($middleware, 'Comserv::Middleware::ApiDomainDetector');

subtest 'Configuration loading' => sub {
    my $config = $middleware->config;
    
    ok(defined $config, 'Configuration loaded');
    is($config->{current_environment}, 'development', 'Current environment is development');
    is($config->{environments}{development}{external_domain}, 
       'api.workstation.local', 
       'Development external domain correct');
    is_deeply($config->{environments}{development}{local_domains},
              ['*.local', 'localhost', '127.0.0.1'],
              'Development local domains correct');
};

subtest 'Domain matching - exact match' => sub {
    ok($middleware->_domain_matches('localhost', 'localhost'), 
       'localhost matches localhost');
    ok($middleware->_domain_matches('127.0.0.1', '127.0.0.1'), 
       '127.0.0.1 matches 127.0.0.1');
    ok(!$middleware->_domain_matches('localhost', '127.0.0.1'), 
       'localhost does not match 127.0.0.1');
};

subtest 'Domain matching - wildcard patterns' => sub {
    ok($middleware->_domain_matches('api.workstation.local', '*.local'), 
       'api.workstation.local matches *.local');
    ok($middleware->_domain_matches('test.local', '*.local'), 
       'test.local matches *.local');
    ok($middleware->_domain_matches('sub.domain.local', '*.local'), 
       'sub.domain.local matches *.local');
    ok(!$middleware->_domain_matches('api.example.com', '*.local'), 
       'api.example.com does not match *.local');
    ok($middleware->_domain_matches('local', '*.local'), 
       'local matches *.local (suffix only)');
};

subtest 'PSGI middleware call - local domain' => sub {
    my $env = {
        HTTP_HOST => 'api.workstation.local:3000',
        REQUEST_METHOD => 'GET',
        PATH_INFO => '/api/todos'
    };
    
    my $response = $middleware->call($env);
    
    is($env->{'comserv.api.is_local_domain'}, 1, 
       'is_local_domain flag set to 1 for *.local domain');
    is($env->{'comserv.api.request_domain'}, 'api.workstation.local', 
       'request_domain set correctly (port stripped)');
};

subtest 'PSGI middleware call - external domain' => sub {
    my $env = {
        HTTP_HOST => 'api.computersystemconsulting.ca',
        REQUEST_METHOD => 'GET',
        PATH_INFO => '/api/todos'
    };
    
    my $response = $middleware->call($env);
    
    is($env->{'comserv.api.is_local_domain'}, 0, 
       'is_local_domain flag set to 0 for external domain (not in local_domains list)');
    is($env->{'comserv.api.request_domain'}, 'api.computersystemconsulting.ca', 
       'request_domain set correctly');
};

subtest 'PSGI middleware call - localhost' => sub {
    my $env = {
        HTTP_HOST => 'localhost:3000',
        REQUEST_METHOD => 'GET',
        PATH_INFO => '/api/todos'
    };
    
    my $response = $middleware->call($env);
    
    is($env->{'comserv.api.is_local_domain'}, 1, 
       'is_local_domain flag set to 1 for localhost');
    is($env->{'comserv.api.request_domain'}, 'localhost', 
       'request_domain set correctly');
};

subtest 'Production environment - local bypass disabled' => sub {
    my $prod_config = {
        environments => {
            production => {
                external_domain => 'api.computersystemconsulting.ca',
                local_domains => [],
                require_https => 1,
                local_bypass_enabled => 0
            }
        },
        current_environment => 'production'
    };
    
    my $prod_config_path = path($tempdir, 'api_domains_prod.json');
    $prod_config_path->spew_utf8(encode_json($prod_config));
    
    my $prod_middleware = Comserv::Middleware::ApiDomainDetector->new(
        config_path => $prod_config_path->stringify,
        app => sub { 
            my $env = shift;
            return [200, ['Content-Type' => 'text/plain'], ['OK']];
        }
    );
    
    my $env = {
        HTTP_HOST => 'api.workstation.local',
        REQUEST_METHOD => 'GET',
        PATH_INFO => '/api/todos'
    };
    
    my $response = $prod_middleware->call($env);
    
    is($env->{'comserv.api.is_local_domain'}, 0, 
       'is_local_domain flag set to 0 when local_bypass_enabled is false');
};

subtest 'Missing configuration file - uses defaults' => sub {
    my $missing_config_path = path($tempdir, 'nonexistent.json');
    
    my $default_middleware = Comserv::Middleware::ApiDomainDetector->new(
        config_path => $missing_config_path->stringify,
        app => sub { 
            my $env = shift;
            return [200, ['Content-Type' => 'text/plain'], ['OK']];
        }
    );
    
    my $config = $default_middleware->config;
    
    ok(defined $config, 'Default configuration created');
    is($config->{current_environment}, 'development', 
       'Default environment is development');
    ok($config->{environments}{development}{local_bypass_enabled}, 
       'Default has local_bypass_enabled');
};

subtest 'Port stripping from Host header' => sub {
    my $env = {
        HTTP_HOST => 'api.workstation.local:8080',
        REQUEST_METHOD => 'GET',
        PATH_INFO => '/api/todos'
    };
    
    my $response = $middleware->call($env);
    
    is($env->{'comserv.api.request_domain'}, 'api.workstation.local', 
       'Port correctly stripped from Host header');
};

subtest 'Empty Host header handling' => sub {
    my $env = {
        HTTP_HOST => '',
        REQUEST_METHOD => 'GET',
        PATH_INFO => '/api/todos'
    };
    
    my $response = $middleware->call($env);
    
    is($env->{'comserv.api.request_domain'}, '', 
       'Empty Host header handled gracefully');
    is($env->{'comserv.api.is_local_domain'}, 0, 
       'is_local_domain is 0 for empty host');
};

done_testing();
