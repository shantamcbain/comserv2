#!/usr/bin/env perl
# Classify matching rows: genuine ENCY-system refs vs incidental "...ency" words.
use strict;
use warnings;
use lib 'Comserv/lib';

use Comserv::Model::RemoteDB;
use Comserv::Model::Schema::Ency;

my $remote_db = Comserv::Model::RemoteDB->new;
my $info = $remote_db->get_connection_info('ency');
my $conn = $info->{config};
my $dsn = $conn->{db_type} eq 'sqlite'
    ? "dbi:SQLite:dbname=$conn->{database_path}"
    : "dbi:mysql:database=$conn->{database};host=$conn->{host};port=$conn->{port}";
my $schema = Comserv::Model::Schema::Ency->connect(
    $dsn, $conn->{username}, $conn->{password},
    { RaiseError => 1, PrintError => 0 },
);

my @all = $schema->resultset('Todo')->search(
    { subject => { like => '%ENCY%' }, sitename => { '!=' => 'ENCY' } },
    { order_by => { -asc => 'record_id' } },
)->all;

print "TOTAL matching `subject LIKE '%ENCY%' AND sitename<>'ENCY'`: ", scalar(@all), "\n\n";

my (@genuine, @incidental);
for my $t (@all) {
    my $s = $t->subject;
    # Incidental = ENCY only appears mid/end of a longer word (preceded by a
    # letter other than a space/punct/hash), e.g. currENCY, consistENCY.
    # Genuine = "ENCY" as a token: ENCY, ENCY:, [ency-..., ENCY/, Ency., ENCY system, etc.
    if ($s =~ /(^|[^A-Za-z])(ENCY|Ency|ency)/) {
        push @genuine, $t;
    } else {
        push @incidental, $t;
    }
}

print "=== GENUINE ENCY-system refs (preceded by non-letter boundary): ", scalar(@genuine), " ===\n";
for my $t (@genuine) { printf "  rec=%-5d %-10s %s\n", $t->record_id, $t->sitename, substr($t->subject,0,70); }

print "\n=== INCIDENTAL '...ency' word matches (likely FALSE POSITIVES): ", scalar(@incidental), " ===\n";
for my $t (@incidental) { printf "  rec=%-5d %-10s %s\n", $t->record_id, $t->sitename, substr($t->subject,0,70); }
