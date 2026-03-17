use strict;
use warnings;
use lib qw(/home/shanta/PycharmProjects/comserv2/Comserv/lib);
use Comserv::Model::Schema::Ency;
use DateTime;
use Data::Dumper;

my $schema = Comserv::Model::Schema::Ency->connect(
    "dbi:mysql:database=ency;host=192.168.1.198",
    "comserv",
    "comserv_pass",
    { quote_names => 1, mysql_enable_utf8 => 1 }
);

my @workshops = $schema->resultset('WorkShop')->all;

print "Total workshops: " . scalar(@workshops) . "\n\n";

for my $w (@workshops) {
    printf "ID: %d | Title: %20s | Site: %10s | Share: %8s | Status: %10s | Date: %s\n",
        $w->id,
        $w->title // 'N/A',
        $w->sitename // 'N/A',
        $w->share // 'N/A',
        $w->status // 'N/A',
        $w->date // 'N/A';
}
