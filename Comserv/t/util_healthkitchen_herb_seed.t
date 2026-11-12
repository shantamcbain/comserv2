use strict; use warnings;
use Test::More;
use lib 'lib';
use Comserv::Util::HealthKitchen::EncyHerbSeed;
my $S = 'Comserv::Util::HealthKitchen::EncyHerbSeed';
my $h = $S->can('herbs')->();
is scalar @$h, 7, 'seven herbs/foods';
my %sym = map { $_->{name} => 1 } @{ $S->can('symptoms')->() };
for my $x (@$h) {
    like $x->{botanical_name}, qr/^[A-Z][a-z]+ [a-z]+/, "$x->{key_name}: binomial";
    like $x->{history}, qr/(African|European|Chinese|Indigenous|Mediterranean|Nordic|Swedish)/, "$x->{key_name}: tradition named";
    like $x->{reference}, qr/^Research: .*(doi:|PMID)/, "$x->{key_name}: research note cites a source";
    unlike join( ' ', @$x{qw(history culinary reference)} ), qr/\b\d+\s*(mg|ml|g)\b|\bcures?\b|\bdose\b/i, "$x->{key_name}: no dosage/cure wording";
    ok $sym{$_}, "$x->{key_name}: symptom '$_' is seeded" for @{ $x->{symptoms} };
}
my $m = $S->can('merge_text');
is $m->( '', 'new' ), 'new', 'fills empty';
is $m->( 'old', 'new' ), "old\n\n$Comserv::Util::HealthKitchen::EncyHerbSeed::MARK new", 'appends once';
is $m->( "old\n\n$Comserv::Util::HealthKitchen::EncyHerbSeed::MARK new", 'new' ), undef, 'idempotent';
done_testing;
