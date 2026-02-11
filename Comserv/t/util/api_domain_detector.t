#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Path::Tiny;
use JSON::MaybeXS;

use FindBin;
use lib "$FindBin::Bin/../../lib";

use_ok('Comserv::Util::ApiDomainDetector');

subtest 'Domain matching - exact match' => sub {
    ok(Comserv::Util::ApiDomainDetector->_domain_matches('localhost', 'localhost'), 
       'localhost matches localhost');
    ok(Comserv::Util::ApiDomainDetector->_domain_matches('127.0.0.1', '127.0.0.1'), 
       '127.0.0.1 matches 127.0.0.1');
    ok(!Comserv::Util::ApiDomainDetector->_domain_matches('localhost', '127.0.0.1'), 
       'localhost does not match 127.0.0.1');
};

subtest 'Domain matching - wildcard patterns' => sub {
    ok(Comserv::Util::ApiDomainDetector->_domain_matches('api.workstation.local', '*.local'), 
       'api.workstation.local matches *.local');
    ok(Comserv::Util::ApiDomainDetector->_domain_matches('test.local', '*.local'), 
       'test.local matches *.local');
    ok(Comserv::Util::ApiDomainDetector->_domain_matches('sub.domain.local', '*.local'), 
       'sub.domain.local matches *.local');
    ok(!Comserv::Util::ApiDomainDetector->_domain_matches('api.example.com', '*.local'), 
       'api.example.com does not match *.local');
    ok(Comserv::Util::ApiDomainDetector->_domain_matches('local', '*.local'), 
       'local matches *.local (suffix only)');
};

subtest 'Configuration loading with defaults' => sub {
    my $config = Comserv::Util::ApiDomainDetector->_load_config();
    
    ok(defined $config, 'Configuration loaded (or defaults created)');
    ok(exists $config->{environments}, 'Has environments key');
    ok(exists $config->{current_environment}, 'Has current_environment key');
};

done_testing();
