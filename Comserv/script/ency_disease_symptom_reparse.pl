#!/usr/bin/env perl
# Re-parse ency_disease_tb.symptoms_description into symptom records + disease_symptom links,
# then simulate herb_symptom text matches. DRY RUN by default.
#   perl script/ency_disease_symptom_reparse.pl            # dry run (no writes)
#   perl script/ency_disease_symptom_reparse.pl --apply    # NOT YET APPROVED: writes in one transaction
# Uses the fixed ENCYModel::_split_terms / _draft_clean_term. Dedupe is exact, case-insensitive.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Getopt::Long;
use Comserv;
use Comserv::Model::ENCYModel;

my ( $apply, $include_questionable ) = ( 0, 0 );
GetOptions( 'apply' => \$apply, 'include-questionable' => \$include_questionable ) or die "usage: $0 [--apply] [--include-questionable]\n";
my $M = 'Comserv::Model::ENCYModel';
my %STOP = map { $_ => 1 } qw(and or the a an of in on at to with for by from as is are was were be been being
    have has had do does did will would could should may might shall can not no nor but if then than also both either neither);
my %BODY = map { $_ => 1 } qw(head face neck chest back arm arms leg legs hand hands foot feet skin eye eyes ear ears nose mouth
    throat abdomen stomach liver kidney kidneys heart lungs lung joint joints muscle muscles bone bones scalp lips tongue teeth
    gums trunk body extremities limbs fingers toes groin genitals breast breasts shoulder shoulders hip hips knee knees);

# Raw names already cleaned/renamed by ency_symptom_cleanup.pl (old text still in disease rows).
my %ALIAS = ( 'appearance of comedones' => 'comedones', 'flayil chse' => 'flail chest', 'pneumothrorax' => 'pneumothorax' );
my %NOT_SYMPTOM = map { $_ => 1 } qw(hair excess cracking heat cold dampness wind dryness deficiency stagnation);

sub questionable {
    my ($t) = @_;
    my $lc = lc $t;
    return 'body part' if $BODY{$lc};
    return 'too short' if length($t) < 4;
    my @w = split /\s+/, $t;
    return 'long (4-5 words)' if @w >= 4;
    return 'fragment' if $lc =~ /^(?:of|in|on|with|to|from|by|for|at|as|or|and)\b/ || $lc =~ /\b(?:of|in|on|with|to|and|or|the)$/;
    return 'has digits' if $t =~ /\d/;
    return 'not a symptom word' if $NOT_SYMPTOM{$lc};
    return 'not a symptom word' if $lc eq 'mucous membranes' || $lc =~ /^(?:other|various|etc|usually|often|sometimes|severe|mild|acute|chronic|symptoms?|signs?)$/;
    return '';
}

my $s = Comserv->model('DBEncy');
my $dsn = $s->storage->connect_info->[0];
$dsn = $dsn->{dsn} if ref $dsn;
print "DSN: $dsn\nMODE: ", ( $apply ? 'APPLY' : 'DRY RUN (no writes)' ), "\n\n";

my %existing = map { ( lc( $_->name ) => $_->record_id ) } $s->resultset('Ency::Symptom')->all;
my %have_link = map { ( $_->disease_id . ':' . $_->symptom_id => 1 ) } $s->resultset('Ency::DiseaseSymptom')->all;

my ( %freq, %display, %diseases_for, %why, $n_dis, $n_with_text, $raw_terms, $dropped );
for my $d ( $s->resultset('Ency::Disease')->search( {}, { columns => [qw(record_id symptoms_description)] } )->all ) {
    $n_dis++;
    my $txt = $d->symptoms_description;
    next unless defined $txt && $txt =~ /\S/;
    $n_with_text++;
    my %seen_here;
    for my $raw ( $M->_split_terms($txt) ) {
        $raw =~ s/^\s+|\s+$//g;
        next if $raw eq '' || $STOP{ lc $raw };
        $raw_terms++;
        my $t = $M->_draft_clean_term( 'Symptom', $raw );
        unless ( length $t ) { $dropped++; next }
        $t = ucfirst $t;
        my $k = lc $t;
        $k = $ALIAS{$k} if $ALIAS{$k};
        next if $seen_here{$k}++;
        $freq{$k}++;
        $display{$k} //= $t;
        push @{ $diseases_for{$k} }, $d->record_id;
        $why{$k} //= questionable($t);
    }
}

my @new_keys = grep { !exists $existing{$_} } keys %freq;
my @good     = grep { $include_questionable || !$why{$_} } @new_keys;
my @quest    = grep { $why{$_} } @new_keys;
my %final    = ( %existing, map { ( $_ => "NEW:$_" ) } @good );    # name => id or placeholder

my ( $links_new, $links_existing_sym ) = ( 0, 0 );
for my $k ( keys %freq ) {
    next unless exists $final{$k};
    for my $did ( @{ $diseases_for{$k} } ) {
        my $sid = $final{$k};
        next if $sid =~ /^\d+$/ && $have_link{"$did:$sid"};
        $sid =~ /^\d+$/ ? $links_existing_sym++ : $links_new++;
    }
}

printf "== Parse ==\n  diseases: %d (with symptom text: %d)\n  raw terms: %d, rejected by cleaner: %d\n  distinct cleaned terms: %d (already existing: %d, new: %d)\n",
    $n_dis, $n_with_text // 0, $raw_terms // 0, $dropped // 0, scalar keys %freq, scalar( keys %freq ) - @new_keys, scalar @new_keys;
printf "  new terms kept: %d, held back as questionable: %d%s\n", scalar @good, scalar @quest, $include_questionable ? ' (included by flag)' : '';

print "\n== Top 30 terms (diseases mentioning) ==\n";
my @top = ( sort { $freq{$b} <=> $freq{$a} || $a cmp $b } keys %freq )[ 0 .. 29 ];
for my $k ( grep { defined } @top ) {
    printf "  %3d  %-35s %s\n", $freq{$k}, $display{$k}, exists $existing{$k} ? '(exists)' : $why{$k} ? "(questionable: $why{$k})" : '';
}

print "\n== Questionable samples ==\n";
my %by_reason;
push @{ $by_reason{ $why{$_} } }, $display{$_} for sort { $freq{$b} <=> $freq{$a} } @quest;
for my $r ( sort keys %by_reason ) {
    my @l = @{ $by_reason{$r} };
    printf "  %-20s %3d: %s\n", $r, scalar @l, join( '; ', @l[ 0 .. ( $#l < 11 ? $#l : 11 ) ] );
}

print "\n== Simulated herb_symptom text matches (new + existing symptom set) ==\n";
my @herbs = $s->resultset('Ency::Herb')->search( {}, { columns => [qw(record_id botanical_name common_names therapeutic_action medical_uses)] } )->all;
my %hs_have = map { ( $_->herb_id . ':' . $_->symptom_id => 1 ) } $s->resultset('Ency::HerbSymptom')->all;
my ( $hs_n, %hs_per, @hs_samples, %herbs_hit );
for my $k ( sort keys %final ) {
    my $name = $display{$k} // $k;
    next if length($name) < 4;
    my $re = qr/(?<![A-Za-z\-])\Q$name\E(?![A-Za-z])/i;
    for my $h (@herbs) {
        my $sid = $final{$k};
        next if $sid =~ /^\d+$/ && $hs_have{ $h->record_id . ":$sid" };
        for my $f (qw(medical_uses therapeutic_action)) {
            my $txt = $h->$f // '';
            next unless $txt =~ $re;
            next if $txt =~ /(?:causes?|may cause|side effects?)[^.;]{0,40}\Q$name\E/i;
            $hs_n++; $hs_per{$name}++; $herbs_hit{ $h->record_id } = 1;
            my ($ctx) = $txt =~ /(.{0,35}\Q$name\E.{0,35})/is;
            push @hs_samples, sprintf( "  herb #%-4d %-26s ~ %-22s [%s] \"...%s...\"", $h->record_id,
                substr( $h->common_names || $h->botanical_name || '', 0, 26 ), $name, $f, $ctx // '' );
            last;
        }
    }
}
printf "  proposed new herb_symptom links: %d across %d herbs and %d symptoms\n", $hs_n // 0, scalar keys %herbs_hit, scalar keys %hs_per;
print "  per symptom: ", join( ', ', map { "$_=$hs_per{$_}" } sort { $hs_per{$b} <=> $hs_per{$a} } keys %hs_per ), "\n" if %hs_per;
my $step = @hs_samples > 20 ? int( @hs_samples / 20 ) : 1;
print "$hs_samples[$_ * $step]\n" for 0 .. ( @hs_samples > 20 ? 19 : $#hs_samples );

printf "\n== Writes if applied ==\n  INSERT ency_symptom_tb: %d\n  INSERT disease_symptom: %d (to new symptoms: %d, to existing symptoms: %d)\n  INSERT herb_symptom (text_match): %d\n",
    scalar @good, $links_new + $links_existing_sym, $links_new, $links_existing_sym, $hs_n // 0;

if ($apply) {
    die "--apply is not implemented until the dry-run numbers are approved.\n";
}
print "\nDry run only. Nothing was written.\n";
