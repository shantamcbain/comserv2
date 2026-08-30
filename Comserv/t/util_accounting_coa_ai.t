use strict;
use warnings;
use Test::More;
use lib 'lib';
use Comserv::Util::Accounting::CoaAiGenerate;

my $g = Comserv::Util::Accounting::CoaAiGenerate->new;

is $g->default_entity_type('nonprofit_coop'), 'nonprofit';
is $g->default_entity_type('service_consulting'), 'sole_proprietor';
is $g->normalize_entity_type('corporation', 'service_consulting'), 'corporation';
is $g->normalize_entity_type('nope', 'nonprofit_coop'), 'nonprofit';

my $v = $g->validate_row({
    accno => '9470', description => 'Honey / apiary revenue',
    category => 'I', gifi_accno => '9470', action => 'add',
});
ok $v, 'valid farming revenue row';
is $v->{category}, 'I';

ok !$g->validate_row({ accno => 'xx', description => 'nope', category => 'Z' });
my $drop = $g->validate_row({
    accno => '6210', description => 'Filament', category => 'E', action => 'drop',
});
is $drop->{action}, 'drop';
my $locked = $g->validate_row({
    accno => '1000', description => 'Cash', category => 'A', action => 'drop', in_use => 1,
});
is $locked->{action}, 'keep', 'in_use cannot drop';

my $starting = [
    { accno => '1000', description => 'Cash', category => 'A', in_use => 1, hits => 3, source => 'maria' },
    { accno => '6210', description => 'Filament', category => 'E', in_use => 0, hits => 0, source => 'maria' },
];
my $ai = [
    { accno => '1000', description => 'Cash', category => 'A', action => 'keep' },
    { accno => '4215', description => 'Print revenue', category => 'I', action => 'add' },
];
$_ = $g->validate_row($_) for @$ai;
my $out = $g->reconcile_draft($starting, $ai);
my %by = map { $_->{accno} => $_ } @$out;
is $by{'1000'}{action}, 'keep';
is $by{'6210'}{action}, 'drop', 'omitted unused Maria row is dropped';
is $by{'4215'}{action}, 'add';

my ($parsed, $err) = $g->parse_accounts_json(<<'JSON');
{"notes":"ok","accounts":[{"accno":"1000","description":"Cash","category":"A"}]}
JSON
ok !$err;
is $parsed->{accounts}[0]{accno}, '1000';

($parsed, $err) = $g->parse_accounts_json("here is junk");
ok $err;

done_testing;
