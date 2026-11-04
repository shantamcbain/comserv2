use strict; use warnings;
use Test::More;
use File::Temp qw(tempdir);
# A Starman worker must leave via POSIX::_exit so DBI END/global destruction
# never runs over shared handles. Simulate: an earlier END (stands in for
# DBI's disconnect_all) must NOT run in a "starman worker", but must run elsewhere.
open my $fh, '<', 'script/comserv_server.psgi' or die $!;
my $psgi = do { local $/; <$fh> };
my ($end) = $psgi =~ /(END \{\n    if \(\(\$0 \/\/ ''\) =~ \/\^starman worker\/\).*?\n\}\n)/s;
ok $end, 'psgi has the worker _exit END block' or BAIL_OUT('missing');
my $dir = tempdir(CLEANUP => 1);
for my $case (['starman worker ', 0], ['starman master ', 1], ['perl', 1]) {
    my ($name, $expect) = @$case;
    my $mark = "$dir/mark" . int(rand 1e9);
    open my $s, '>', "$dir/s.pl" or die $!;
    print $s "END { open my \$f, '>', '$mark'; }\n\$0 = '$name';\n$end\nexit 3;\n";
    close $s;
    system($^X, "$dir/s.pl");
    is $? >> 8, 3, "$name keeps exit code";
    is((-e $mark ? 1 : 0), $expect, "$name: earlier END " . ($expect ? 'runs' : 'skipped'));
}
open my $ep, '<', 'docker-entrypoint.sh' or die $!;
my $sh = do { local $/; <$ep> };
like $sh, qr/WORKERS="\$\{WORKERS:-8\}"/, 'worker cap defaults to 8';
like $sh, qr/--max-requests "\$MAX_REQUESTS"/, 'max-requests recycling';
done_testing;
