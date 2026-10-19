#!/usr/bin/env perl
# ENCY symptom cleanup + HerbSymptom population from herb text.
# DRY RUN by default: prints every proposed write, changes nothing.
#   perl script/ency_symptom_cleanup.pl            # dry run
#   perl script/ency_symptom_cleanup.pl --apply    # performs the writes in ONE transaction (needs approval)
# Run from Comserv/ (needs logs/). Target DB = whatever DBEncy connects to; check the DSN line first.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Getopt::Long;
use Comserv;

my $apply = 0;
GetOptions( 'apply' => \$apply ) or die "usage: $0 [--apply]\n";

# Reviewed per-row plan for the 19 garbled rows (record_id => action). Unlisted ids are left alone.
my %PLAN = (
    1  => [ rename => 'Comedones' ],
    2  => [ rename => 'Enlarged prostate' ],
    3  => [ delete => 'body location fragment from "chest, face and back"' ],
    4  => [ rename => 'Pneumothorax' ],
    5  => [ rename => 'Flail chest' ],
    6  => [ delete => 'body location fragment, not a symptom' ],
    7  => [ rename => 'Nodules' ],
    8  => [ delete => '"[object Object]" JS serialisation artefact' ],
    9  => [ rename => 'Papules' ],
    10 => [ rename => 'Pustules' ],
    11 => [ rename => 'Nausea' ],
    13 => [ rename => 'Constipation' ],
    16 => [ rename => 'Hepatotoxicity' ],
    17 => [ rename => 'Respiratory depression' ],
    19 => [ rename => 'Dependence or withdrawal' ],
);
my @LINK_TABLES = qw(Ency::DiseaseSymptom Ency::DrugSymptom Ency::HerbSymptom Ency::ConstituentSymptom HealthKitchen::UserActiveSymptom);

my $s = Comserv->model('DBEncy');
my $dsn = $s->storage->connect_info->[0];
$dsn = $dsn->{dsn} if ref $dsn;
print "DSN: $dsn\nMODE: ", ( $apply ? 'APPLY' : 'DRY RUN (no writes)' ), "\n\n";

my ( @writes, %final_name );
print "== Symptom rows ==\n";
for my $sym ( $s->resultset('Ency::Symptom')->search( {}, { order_by => 'record_id' } )->all ) {
    my $id = $sym->record_id;
    my ( $act, $arg ) = @{ $PLAN{$id} || ['keep'] };
    my %links = map { my $n = eval { $s->resultset($_)->search( { symptom_id => $id } )->count } // 'n/a'; ( ( split /::/ )[-1] => $n ) } @LINK_TABLES;
    my $lk = join ' ', map { "$_=$links{$_}" } sort keys %links;
    if ( $act eq 'rename' ) {
        printf "  #%-3d %-50s -> RENAME '%s'   [%s]\n", $id, "'" . $sym->name . "'", $arg, $lk;
        push @writes, [ "UPDATE ency_symptom_tb SET name=?, common_name=? WHERE record_id=?", $arg, $arg, $id ];
        $final_name{$id} = $arg;
    }
    elsif ( $act eq 'delete' ) {
        printf "  #%-3d %-50s -> DELETE (%s)   [%s]\n", $id, "'" . $sym->name . "'", $arg, $lk;
        for my $t (@LINK_TABLES) {
            next unless ( $links{ ( split /::/, $t )[-1] } || 0 ) =~ /^[1-9]/;
            my $table = $s->source($t)->name;
            push @writes, [ "DELETE FROM $table WHERE symptom_id=?", $id ];
        }
        push @writes, [ "DELETE FROM ency_symptom_tb WHERE record_id=?", $id ];
    }
    else {
        printf "  #%-3d %-50s -> keep   [%s]\n", $id, "'" . $sym->name . "'", $lk;
        $final_name{$id} = $sym->name;
    }
}

print "\n== HerbSymptom proposals (whole-word match of symptom name in herb text) ==\n";
my @herbs = $s->resultset('Ency::Herb')->search( {}, { columns => [qw(record_id botanical_name common_names therapeutic_action medical_uses)] } )->all;
my %existing = map { ( $_->herb_id . ':' . $_->symptom_id => 1 ) } $s->resultset('Ency::HerbSymptom')->all;
my ( $n_links, %per_sym, @samples ) = (0);
for my $sid ( sort { $a <=> $b } keys %final_name ) {
    my $name = $final_name{$sid};
    next unless length($name) >= 4;
    my $re = qr/(?<![A-Za-z\-])\Q$name\E(?![A-Za-z])/i;
    for my $h (@herbs) {
        for my $field (qw(medical_uses therapeutic_action)) {
            my $txt = $h->$field // '';
            next unless $txt =~ $re;
            next if $txt =~ /(?:causes?|may cause|side effects?)[^.;]{0,40}\Q$name\E/i;    # adverse effect, not a use
            next if $existing{ $h->record_id . ":$sid" }++;
            $n_links++;
            $per_sym{$name}++;
            my ($ctx) = $txt =~ /(.{0,40}\Q$name\E.{0,40})/is;
            push @samples, sprintf( "  herb #%d %-30s ~ symptom #%d %-22s [%s] \"...%s...\"",
                $h->record_id, substr( $h->common_names || $h->botanical_name || '', 0, 30 ), $sid, $name, $field, $ctx // '' );
            push @writes, [ "INSERT INTO herb_symptom (herb_id, symptom_id, relationship_type, notes) VALUES (?,?,?,?)",
                $h->record_id, $sid, 'text_match', "auto: '$name' found in herb $field (ency_symptom_cleanup.pl); verify" ];
            last;
        }
    }
}
print "  total proposed links: $n_links\n";
print "  per symptom: ", join( ', ', map { "$_=$per_sym{$_}" } sort keys %per_sym ), "\n" if %per_sym;
print "$_\n" for @samples[ 0 .. ( $#samples < 14 ? $#samples : 14 ) ];

printf "\n== Writes: %d statements (%d symptom updates, %d deletes, %d herb_symptom inserts) ==\n",
    scalar @writes, scalar( grep { $_->[0] =~ /^UPDATE/ } @writes ),
    scalar( grep { $_->[0] =~ /^DELETE/ } @writes ), scalar( grep { $_->[0] =~ /^INSERT/ } @writes );
print "  $_->[0]  -- [", join( ', ', @{$_}[ 1 .. $#$_ ] ), "]\n" for grep { $_->[0] !~ /^INSERT/ } @writes;

if ($apply) {
    $s->txn_do( sub { my $dbh = $s->storage->dbh; $dbh->do( $_->[0], undef, @{$_}[ 1 .. $#$_ ] ) for @writes } );
    print "\nAPPLIED in one transaction.\n";
}
else {
    print "\nDry run only. Nothing was written.\n";
}
