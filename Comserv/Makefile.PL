#!/usr/bin/env perl
# IMPORTANT: if you delete this file your app will not work as
# expected.  You have been warned.
use lib '.';
use inc::Module::Install 1.02;
use Module::Install::Catalyst; # Complain loudly if you don't have
                               # Catalyst::Devel installed or haven't said
                               # 'make dist' to create a standalone tarball.

name 'Comserv';
all_from 'lib/Comserv.pm';

requires 'Catalyst::Runtime' => '5.90130';
requires 'Catalyst::Plugin::ConfigLoader';
requires 'Catalyst::Plugin::Static::Simple';
requires 'Catalyst::Action::RenderView';
requires 'Catalyst::Devel';  # This includes Catalyst::ScriptRunner
requires 'Moose';
requires 'namespace::autoclean';
requires 'Config::General'; # This should reflect the config file format you've chosen
                 # See Catalyst::Plugin::ConfigLoader for supported formats
requires 'Config::JSON';
requires 'DBIx::Class::Schema::Loader';
requires 'JSON';
requires 'Try::Tiny';
requires 'Data::Dumper';
requires 'Log::Log4perl';
requires 'File::Slurp';
requires 'DBI';
requires 'DBD::mysql';  # Add other database drivers as needed
requires 'Catalyst::Plugin::Session';
requires 'Catalyst::Plugin::Session::Store::File';
requires 'Catalyst::Plugin::Session::State::Cookie';
requires 'Catalyst::Plugin::Authentication';
requires 'Catalyst::Plugin::Authorization::Roles';
requires 'Catalyst::Plugin::Authorization::ACL';
requires 'Catalyst::Plugin::Log::Dispatch';
requires 'Catalyst::Plugin::StackTrace';
requires 'Log::Dispatch::File';
test_requires 'Test::More' => '0.88';
catalyst;

install_script glob('script/*.pl');
auto_install;
WriteAll;
