#!/usr/bin/env perl
# CLI for Comserv::Util::SiteCloner. Usage:
#   DB_DSN=dbi:mysql:database=ency;host=..;port=.. DB_USER=.. MYSQL_PWD=.. perl script/clone_site.pl <SiteName> <url> [max_pages]
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/../lib";
use Comserv::Model::Schema::Ency;
use Comserv::Util::SiteCloner;
my ($sitename, $url, $max) = @ARGV;
die "usage: $0 SiteName URL [max_pages]\n" unless $sitename && $url;
my $schema = Comserv::Model::Schema::Ency->connect($ENV{DB_DSN}, $ENV{DB_USER}, $ENV{MYSQL_PWD}, { mysql_enable_utf8mb4 => 1 });
my $site = $schema->resultset('Site')->search({ name => $sitename })->single or die "No site '$sitename'\n";
my $cl = Comserv::Util::SiteCloner->new(schema => $schema, sitename => $site->name, site_id => $site->id,
    max_pages => $max // 200, log => sub { print "$_[0]\n" });
my $r = $cl->clone($url);
print "PAGES: @{$r->{pages}}\nIMAGES: $r->{images}\n";
print "ERROR: $_\n" for @{$r->{errors}};
