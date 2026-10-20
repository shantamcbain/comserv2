#!/usr/bin/env perl
# Re-parse ency_disease_tb.symptoms_description into symptom records + disease_symptom links,
# then add herb_symptom text matches. DRY RUN by default.
#   perl script/ency_disease_symptom_reparse.pl                      # dry run (no writes)
#   perl script/ency_disease_symptom_reparse.pl --apply              # backup 3 tables, then write in ONE transaction
#   perl script/ency_disease_symptom_reparse.pl --list               # dry run + full per-term list
# Every write is tagged 'reparse-20261018' (symptom username_of_poster, link notes) for undo:
#   DELETE FROM herb_symptom    WHERE notes LIKE '%reparse-20261018%';
#   DELETE FROM disease_symptom WHERE notes LIKE '%reparse-20261018%';
#   DELETE FROM ency_symptom_tb WHERE username_of_poster='reparse-20261018';
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Getopt::Long;
use POSIX qw(strftime);
use Comserv;
use Comserv::Model::ENCYModel;

my $TAG = 'reparse-20261018';
my ( $apply, $list ) = ( 0, 0 );
GetOptions( 'apply' => \$apply, 'list' => \$list ) or die "usage: $0 [--apply] [--list]\n";
my $M = 'Comserv::Model::ENCYModel';

my %STOP = map { $_ => 1 } qw(and or the a an of in on at to with for by from as is are was were be been being
    have has had do does did will would could should may might shall can not no nor but if then than also both either neither);
my %BODY = map { $_ => 1 } qw(head face neck chest back arm arms leg legs hand hands foot feet skin eye eyes ear ears nose mouth
    throat abdomen stomach liver kidney kidneys heart lungs lung joint joints muscle muscles bone bones scalp lips tongue teeth
    gums trunk body extremities limbs fingers toes groin genitals breast breasts shoulder shoulders hip hips knee knees nails);
my %NOT_SYMPTOM = map { $_ => 1 } ( qw(hair excess cracking heat cold dampness wind dryness deficiency stagnation herbs individual),
    'mucous membranes', 'this indicates treatments', 'varies by trimester', 'vata-related reproductive' );

# Reviewed fixes (Shanta, 2026-10-18). lc(cleaned term) => [ final names ]; [] = drop.
my %FIX = (
    'appearance of comedones'                  => ['Comedones'],
    'flayil chse'                              => ['Flail chest'],
    'pneumothrorax'                            => ['Pneumothorax'],
    'nausea/vomiting'                          => [ 'Nausea', 'Vomiting' ],
    'sore/dry throat'                          => [ 'Sore throat', 'Dry throat' ],
    'high altitude cerebral edema (hape)'      => ['Cerebral edema'],
    'high altitude cerebral edema'             => ['Cerebral edema'],
    'characterized by symptoms like heaviness' => ['Heaviness'],
    'chest pain or tightness'                  => ['Chest pain'],
    'red tongue with yellow coating'           => ['Red tongue'],
    'irregular appetite and energy levels'     => ['Irregular appetite'],
    map { ( $_ => [] ) } ( 'herbs', 'individual', 'nails', 'this indicates treatments', 'varies by trimester', 'vata-related reproductive' ),
);

sub questionable {
    my ($t) = @_;
    my $lc = lc $t;
    return 'body part'          if $BODY{$lc};
    return 'not a symptom word' if $NOT_SYMPTOM{$lc};
    return 'too short'          if length($t) < 4;
    return 'long (4-5 words)'   if ( () = split /\s+/, $t ) >= 4;
    return 'fragment'           if $lc =~ /^(?:of|in|on|with|to|from|by|for|at|as|or|and)\b/ || $lc =~ /\b(?:of|in|on|with|to|and|or|the)$/;
    return 'has digits'         if $t =~ /\d/;
    return '';
}

my $s = Comserv->model('DBEncy');
my $dsn = $s->storage->connect_info->[0];
$dsn = $dsn->{dsn} if ref $dsn;
print "DSN: $dsn\nMODE: ", ( $apply ? 'APPLY' : 'DRY RUN (no writes)' ), "\n\n";

my %existing = map { ( lc( $_->name ) => $_->record_id ) } $s->resultset('Ency::Symptom')->all;
my %have_ds  = map { ( $_->disease_id . ':' . $_->symptom_id => 1 ) } $s->resultset('Ency::DiseaseSymptom')->all;

my ( %freq, %display, %diseases_for, %why, $n_dis, $n_text, $raw_n, $dropped, $fixed_drop );
for my $d ( $s->resultset('Ency::Disease')->search( {}, { columns => [qw(record_id symptoms_description)] } )->all ) {
    $n_dis++;
    my $txt = $d->symptoms_description;
    next unless defined $txt && $txt =~ /\S/;
    $n_text++;
    my %here;
    for my $raw ( $M->_split_terms($txt) ) {
        $raw =~ s/^\s+|\s+$//g;
        next if $raw eq '' || $STOP{ lc $raw };
        $raw_n++;
        my $t = $M->_draft_clean_term( 'Symptom', $raw );
        $t = $raw if !length $t && $FIX{ lc $raw };    # long terms the cleaner rejects but we shorten
        unless ( length $t ) { $dropped++; next }
        my @names = $FIX{ lc $t } ? @{ $FIX{ lc $t } } : ( ucfirst $t );
        $fixed_drop++ unless @names;
        for my $n (@names) {
            my $k = lc $n;
            next if $here{$k}++;
            $freq{$k}++;
            $display{$k} //= $n;
            push @{ $diseases_for{$k} }, $d->record_id;
            $why{$k} //= questionable($n);
        }
    }
}

my @new_keys = grep { !exists $existing{$_} } keys %freq;
my @good  = sort grep { !$why{$_} } @new_keys;
my @quest = grep { $why{$_} } @new_keys;
my %final = ( %existing, map { ( $_ => undef ) } @good );    # undef id = to be created

# disease_symptom links
my @ds;
for my $k ( sort keys %freq ) {
    next unless exists $final{$k};
    for my $did ( @{ $diseases_for{$k} } ) {
        next if defined $final{$k} && $have_ds{"$did:$final{$k}"};
        push @ds, [ $did, $k ];
    }
}

# herb_symptom text matches
my @herbs = $s->resultset('Ency::Herb')->search( {}, { columns => [qw(record_id botanical_name common_names therapeutic_action medical_uses)] } )->all;
my %hs_have = map { ( $_->herb_id . ':' . $_->symptom_id => 1 ) } $s->resultset('Ency::HerbSymptom')->all;
my ( @hs, %hs_per );
for my $k ( sort keys %final ) {
    my $name = $display{$k} // $k;
    next if length($name) < 4;
    my $re = qr/(?<![A-Za-z\-])\Q$name\E(?![A-Za-z])/i;
    for my $h (@herbs) {
        next if defined $final{$k} && $hs_have{ $h->record_id . ":$final{$k}" };
        for my $f (qw(medical_uses therapeutic_action)) {
            my $txt = $h->$f // '';
            next unless $txt =~ $re;
            next if $txt =~ /(?:causes?|may cause|side effects?)[^.;]{0,40}\Q$name\E/i;
            push @hs, [ $h->record_id, $k, $f, $name ];
            $hs_per{$name}++;
            last;
        }
    }
}

printf "== Parse ==\n  diseases: %d (with symptom text: %d)\n  raw terms: %d, rejected by cleaner: %d, dropped by review: %d\n  distinct terms: %d (existing: %d, new kept: %d, held back: %d)\n",
    $n_dis, $n_text // 0, $raw_n // 0, $dropped // 0, $fixed_drop // 0, scalar keys %freq, scalar( keys %freq ) - @new_keys, scalar @good, scalar @quest;
print "  held back: ", join( '; ', map { "$display{$_} ($why{$_})" } sort @quest ), "\n" if @quest;
if ($list) {
    my %dname = map { ( $_->record_id => $_->common_name // $_->record_id ) } $s->resultset('Ency::Disease')->all;
    printf "  NEW %s | %s | herbs=%d\n", $display{$_}, join( '; ', map { $dname{$_} } @{ $diseases_for{$_} } ), $hs_per{ $display{$_} } // 0 for @good;
}
printf "\n== Writes ==\n  INSERT ency_symptom_tb: %d\n  INSERT disease_symptom: %d\n  INSERT herb_symptom (text_match): %d\n  herb links per symptom: %s\n",
    scalar @good, scalar @ds, scalar @hs, join( ', ', map { "$_=$hs_per{$_}" } sort { $hs_per{$b} <=> $hs_per{$a} } keys %hs_per );

unless ($apply) { print "\nDry run only. Nothing was written.\n"; exit 0 }

die "Refusing: unexpected DSN $dsn\n" unless $dsn =~ /database=ency;host=192\.168\.1\.20;port=3307/;
die "Refusing: rows tagged $TAG already exist (already applied?)\n"
    if $s->resultset('Ency::Symptom')->search( { username_of_poster => $TAG } )->count;

# Backup via the app connection
my $dbh = $s->storage->dbh;
my $bdir = "$ENV{HOME}/.comserv/backups";
mkdir $bdir, 0700 unless -d $bdir;
my $bfile = "$bdir/ency_symptom_reparse_" . strftime( '%Y%m%d_%H%M%S', localtime ) . ".sql";
{
    umask 077;
    open my $fh, '>', $bfile or die "backup: $!\n";
    print $fh "-- backup before $TAG from $dsn\nSET FOREIGN_KEY_CHECKS=0;\n";
    for my $t (qw(ency_symptom_tb disease_symptom herb_symptom)) {
        my ( undef, $create ) = $dbh->selectrow_array("SHOW CREATE TABLE `$t`");
        print $fh "\nDROP TABLE IF EXISTS `$t`;\n$create;\n";
        my $sth = $dbh->prepare("SELECT * FROM `$t`");
        $sth->execute;
        my $cols = join ',', map {"`$_`"} @{ $sth->{NAME} };
        my $n = 0;
        while ( my $r = $sth->fetchrow_arrayref ) {
            $n++;
            print $fh "INSERT INTO `$t` ($cols) VALUES (" . join( ',', map { defined $_ ? $dbh->quote($_) : 'NULL' } @$r ) . ");\n";
        }
        print "BACKUP $t rows=$n\n";
    }
    print $fh "SET FOREIGN_KEY_CHECKS=1;\n";
    close $fh or die "backup close: $!\n";
    die "backup empty\n" unless -s $bfile;
}
print "BACKUP FILE $bfile\n";

my $today = strftime( '%Y-%m-%d', localtime );
$s->txn_do( sub {
    for my $k (@good) {
        my $row = $s->resultset('Ency::Symptom')->create( {
            name => $display{$k}, common_name => $display{$k}, sitename => 'ENCY',
            username_of_poster => $TAG, group_of_poster => 'admin', date_time_posted => $today, share => 0 } );
        $final{$k} = $row->record_id;
    }
    $s->resultset('Ency::DiseaseSymptom')->create( { disease_id => $_->[0], symptom_id => $final{ $_->[1] }, notes => "$TAG: parsed from symptoms_description" } ) for @ds;
    $s->resultset('Ency::HerbSymptom')->create( {
        herb_id => $_->[0], symptom_id => $final{ $_->[1] }, relationship_type => 'text_match',
        notes => "auto: '$_->[3]' found in herb $_->[2] ($TAG); verify" } ) for @hs;
} );
print "\nAPPLIED in one transaction.\n";
