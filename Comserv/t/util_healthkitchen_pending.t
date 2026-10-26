use strict;
use warnings;
use utf8;
use Test::More;
use lib 'lib';
use Comserv::Util::HealthKitchen;

my $hk = Comserv::Util::HealthKitchen->new;

is $hk->clean_text('<b>Sore</b> throat'), 'Sore throat', 'tags stripped';
is $hk->clean_text("<script>alert(1)</script>Itch"), 'alert(1)Itch', 'script tags stripped';
is $hk->clean_text("a\x00b\x07c"), 'abc', 'control chars removed';
is $hk->clean_text("x <!-- hi --> y"), 'x y', 'comments removed';
is $hk->clean_text('1 < 2'), '1 2', 'stray angle brackets removed';

my ( $v, $e ) = $hk->validate_symptom_submission(
    { name => '  Night   sweats ', description => '<i>wakes</i> drenched', severity => 'moderate' } );
is $e, undef, 'valid';
is_deeply $v, { name => 'Night sweats', description => 'wakes drenched', severity => 'moderate' }, 'cleaned payload';

( $v, $e ) = $hk->validate_symptom_submission( { name => 'Douleur à l’épaule' } );
like $e // '', qr/may only contain/, 'curly apostrophe rejected';
( $v, $e ) = $hk->validate_symptom_submission( { name => "Douleur à l'épaule (gauche)" } );
is $e, undef, 'accented letters + allowed punctuation ok';
is $v->{description}, undef, 'empty description -> undef';

for my $bad ( '', 'x', 'a' x 121, 'Pain; DROP TABLE x', 'Pain & ache', '-leading dash', '"quoted"' ) {
    ( undef, $e ) = $hk->validate_symptom_submission( { name => $bad } );
    ok $e, "rejected: " . substr( $bad, 0, 20 );
}
( undef, $e ) = $hk->validate_symptom_submission( { name => 'Ok name', description => 'd' x 2001 } );
like $e, qr/2000/, 'description too long';
( undef, $e ) = $hk->validate_symptom_submission( { name => 'Ok name', severity => 's' x 41 } );
like $e, qr/Severity/, 'severity too long';
( $v, $e ) = $hk->validate_symptom_submission( { name => '<b></b>' } );
like $e, qr/required/, 'HTML-only name is empty';

done_testing;
