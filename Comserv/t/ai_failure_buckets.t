use strict; use warnings;
use Test::More;
use FindBin; use lib "$FindBin::Bin/../lib";
use Comserv::Model::AI2::UsageMonitor;
my $m = Comserv::Model::AI2::UsageMonitor->new;
is $m->classify_failure_reason('success', ''), 'success';
is $m->classify_failure_reason('error', 'OpenRouter provider error: 429 Too Many Requests'), 'http_429';
is $m->classify_failure_reason('error', '404 No endpoints found'), 'http_404';
is $m->classify_failure_reason('error', '402 Payment Required'), 'http_402';
is $m->classify_failure_reason('error', 'timeout waiting for upstream'), 'timeout';
is $m->classify_failure_reason('error', 'empty_output: provider returned success with no text'), 'empty';
is $m->classify_failure_reason('all_exhausted', 'No AI model is available'), 'all_exhausted';
is $m->classify_failure_reason('error', 'circuit_open on model'), 'circuit_open';
is $m->classify_failure_reason('error', 'budget_cap_day'), 'budget_cap';
is $m->classify_failure_reason('trip', 'whatever'), 'other';  # trip excluded upstream; classify still returns other
is $m->classify_failure_reason('error', 'something weird'), 'other';
done_testing;
