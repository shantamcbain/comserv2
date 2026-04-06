use strict;
use warnings;
use Test::More;
use Test::WWW::Mechanize::Catalyst;
use JSON;

# Create the mechanize object for testing
my $mech = Test::WWW::Mechanize::Catalyst->new(catalyst_app => 'Comserv');

# 1. Test the /status/memory endpoint
$mech->get_ok('/status/memory', 'Request to /status/memory');

# Extract JSON from content (might contain debug info if CATALYST_DEBUG is on)
my $content = $mech->content;
my $json_str = $content;
if ($content =~ /(\{.*\})/s) {
    $json_str = $1;
}

my $json = eval { decode_json($json_str) };
ok($json, 'Response contains valid JSON') or diag("Raw content: $content\nError: $@");

if ($json) {
    is(ref($json), 'HASH', 'JSON root is a hash');
    ok($json->{memory}, 'JSON contains memory key');
    ok($json->{pid}, 'JSON contains pid key');
    
    # Check if we have Linux memory stats
    if ($json->{memory}->{VmRSS}) {
        pass("Response contains VmRSS memory statistic");
    } else {
        diag("Memory stats received: " . join(", ", keys %{$json->{memory}}));
        # We don't fail here if not on Linux, but the earlier grep showed it exists
    }
}

# 2. Test that navigation pages still work
$mech->get_ok('/', 'Request to root page');

done_testing();
