package Comserv::Util::HealthKitchen::EncyHerbSeed;
use strict;
use warnings;
use utf8;

# Idempotent ENCY seed: prostate / urinary health herbs and foods, prevention and
# traditional-use focus. Informational only: no dosages, no cure claims.
# Rules (see ensure()):
#   - Herb matched by botanical genus+species prefix; created if missing.
#   - Existing herbs: empty fields are filled; non-empty text fields get our text
#     appended once, behind a marker, so staff edits are never overwritten.
#   - Symptoms matched by name (case-insensitive); herb_symptom links by
#     (herb_id, symptom_id, relationship_type) unique key.
# Run automatically by Comserv::Util::HealthKitchen::ensure_ency_herb_seed.

our $MARK    = '[HealthKitchen prostate seed]';
our $REL     = 'traditional_use';
our $VERSION_TAG = 'prostate-2026-11';

our @SYMPTOMS = (
    { name => 'Frequent urination', body_system => 'urinary' },
    { name => 'Frequent nighttime urination', common_name => 'Nocturia', body_system => 'urinary',
      description => 'Waking at night to pass urine. Common in men as the prostate ages; also linked to evening fluids, caffeine and alcohol.' },
    { name => 'Weak urine flow', common_name => 'Poor stream', body_system => 'urinary',
      description => 'A slow or weak urine stream, sometimes with straining or dribbling. In men often related to prostate changes.' },
);

my $COCH_PYG  = 'Wilt T, Ishani A, Mac Donald R, Rutks I, Stark G. Pygeum africanum for benign prostatic hyperplasia. Cochrane Database Syst Rev. 2002;(1):CD001044. doi:10.1002/14651858.CD001044';
my $COCH_BSIT = 'Wilt T, Ishani A, MacDonald R, Stark G, Mulrow C, Lau J. Beta-sitosterols for benign prostatic hyperplasia. Cochrane Database Syst Rev. 2000;(2):CD001043. doi:10.1002/14651858.CD001043';

our @HERBS = (
    {
        botanical_name => 'Prunus africana (Hook.f.) Kalkman',
        key_name       => 'Pygeum',
        common_names   => 'Pygeum; African cherry; African plum; Red stinkwood',
        parts_used     => 'Bark',
        constituents   => 'Phytosterols including beta-sitosterol; pentacyclic triterpenes (ursolic, oleanolic acids); ferulic acid esters.',
        history        => 'African traditional medicine: bark decoctions have long been used in Cameroon, Kenya, Madagascar and southern Africa for urinary complaints of older men, often called "old man\'s disease". Adopted into European herbalism (France) in the 1960s. Ethics: the tree is listed in CITES Appendix II because bark harvest has depleted wild stands; prefer certified sustainable sources.',
        culinary       => 'Not a food. Prevention focus is the whole diet: plant sterols from nuts, seeds, legumes and whole grains (the same sterol family found in pygeum bark).',
        reference      => "Research: $COCH_PYG (18 small, short trials, 1562 men: moderate improvement in urinary symptoms and flow, nocturia reduced, well tolerated; longer, larger trials needed). Constituent beta-sitosterol: $COCH_BSIT",
        symptoms       => [ 'Frequent urination', 'Frequent nighttime urination', 'Weak urine flow' ],
    },
    {
        botanical_name => 'Serenoa repens (W.Bartram) Small',
        key_name       => 'Saw palmetto',
        common_names   => 'Saw palmetto; Sabal',
        parts_used     => 'Fruit (berry)',
        constituents   => 'Fatty acids (lauric, oleic, myristic); phytosterols including beta-sitosterol.',
        history        => 'North American Indigenous food: the berries were eaten by Indigenous peoples of the southeastern United States. 19th-century American Eclectic physicians and later European herbalism used the berry as a tonic for the urinary and reproductive organs of older men.',
        culinary       => 'Berries are edible but strong-tasting. Prevention focus: a diet rich in plant foods and healthy fats, regular movement and a healthy weight, which are linked with lower rates of urinary symptoms.',
        reference      => 'Research: Bent S, et al. Saw palmetto for benign prostatic hyperplasia (STEP trial). N Engl J Med. 2006;354:557-566. doi:10.1056/NEJMoa053085. Barry MJ, et al. Effect of increasing doses of saw palmetto extract on lower urinary tract symptoms (CAMUS trial). JAMA. 2011;306(12):1344-1351. Both trials tested one standardized extract in men with established symptoms and found no difference from placebo; they did not study whole berries, traditional preparations or long-term prevention.',
        symptoms       => [ 'Frequent urination', 'Frequent nighttime urination' ],
    },
    {
        botanical_name => 'Urtica dioica L.',
        key_name       => 'Stinging nettle',
        common_names   => 'Stinging nettle; Nettle root',
        parts_used     => 'Root; leaf',
        constituents   => 'Root: lignans, beta-sitosterol and other sterols, lectin (UDA), polysaccharides. Leaf: minerals, chlorophyll, flavonoids.',
        history        => 'European herbalism: nettle root has been used for difficult urination in older men; the leaf as a spring cleansing tonic.',
        culinary       => 'Young leaves are a nourishing spring green (cooked or dried for tea; cooking removes the sting). Regular greens support overall health.',
        reference      => 'Research: Safarinejad MR. Urtica dioica for treatment of benign prostatic hyperplasia: a prospective, randomized, double-blind, placebo-controlled, crossover study. J Herb Pharmacother. 2005;5(4):1-11. doi:10.1080/J157v05n04_01 (620 men, 6 months: improved symptom scores and flow versus placebo; author calls for confirmation).',
        symptoms       => [ 'Frequent urination', 'Weak urine flow' ],
    },
    {
        botanical_name => 'Cucurbita pepo L.',
        key_name       => 'Pumpkin seed',
        common_names   => 'Pumpkin; Pumpkin seed; Pepita',
        parts_used     => 'Seed; seed oil',
        constituents   => 'Phytosterols including beta-sitosterol (delta-7 sterols); zinc; magnesium; tocopherols; unsaturated fatty acids.',
        history        => 'European folk medicine, notably Austria and Hungary (Styrian pumpkin seed): seeds eaten for bladder and prostate comfort. Seeds also eaten across the Americas, where the plant was domesticated.',
        culinary       => 'Food: a handful of raw or lightly toasted seeds, or cold-pressed seed oil on salads. A good food source of zinc and magnesium.',
        reference      => 'Research: Vahlensieck W, et al. Effects of pumpkin seed in men with lower urinary tract symptoms due to benign prostatic hyperplasia in the one-year, randomized, placebo-controlled GRANU study. Urol Int. 2015;94(3):286-295. PMID 25196580 (1431 men: whole pumpkin seed showed more responders than placebo, 58.5% vs 47.3%; the capsule extract did not). Constituent beta-sitosterol: ' . $COCH_BSIT,
        symptoms       => [ 'Frequent urination', 'Frequent nighttime urination' ],
    },
    {
        botanical_name => 'Secale cereale L.',
        key_name       => 'Rye grass pollen',
        common_names   => 'Rye; Rye grass pollen; Cernilton (pollen extract)',
        parts_used     => 'Pollen (extract); grain',
        constituents   => 'Pollen: water- and fat-soluble fractions; phytosterols; amino acids. Grain: fibre, lignans.',
        history        => 'Modern European (Swedish) phytotherapy: a rye-grass pollen extract was developed in Sweden in the 1950s and has been used across Europe and Japan for urinary comfort in men. Whole rye grain is a traditional Nordic and Eastern European staple.',
        culinary       => 'Food: whole-grain rye bread and porridge are fibre- and lignan-rich staples of traditional Nordic diets.',
        reference      => 'Research: MacDonald R, Ishani A, Rutks I, Wilt TJ. A systematic review of Cernilton for the treatment of benign prostatic hyperplasia. BJU Int. 2000;85(7):836-841. doi:10.1046/j.1464-410x.2000.00365.x; also Cochrane CD001042 (444 men: modest improvement in self-rated symptoms and nocturia; no change in flow; well tolerated).',
        symptoms       => [ 'Frequent nighttime urination' ],
    },
    {
        botanical_name => 'Solanum lycopersicum L.',
        key_name       => 'Tomato',
        common_names   => 'Tomato; Lycopene source',
        parts_used     => 'Fruit',
        constituents   => 'Lycopene (carotenoid, more available when cooked with oil); vitamin C; potassium; flavonoids.',
        history        => 'Mediterranean diet staple; originally domesticated in Mesoamerica. Cooked tomato sauces with olive oil are traditional in Southern European cooking.',
        culinary       => 'Prevention through food: cooked tomato products (sauce, paste, soup) with a little olive oil release the most lycopene. Enjoy regularly as part of a plant-rich diet.',
        reference      => 'Research: Giovannucci E, Rimm EB, Liu Y, Stampfer MJ, Willett WC. A prospective study of tomato products, lycopene, and prostate cancer risk. J Natl Cancer Inst. 2002;94(5):391-398. doi:10.1093/jnci/94.5.391 (47,365 men followed 12 years: frequent tomato sauce intake associated with lower prostate cancer risk). Observational association, not proof of cause.',
        symptoms       => [],
    },
    {
        botanical_name => 'Camellia sinensis (L.) Kuntze',
        key_name       => 'Green tea',
        common_names   => 'Green tea; Tea plant',
        parts_used     => 'Leaf',
        constituents   => 'Catechins (EGCG, EGC, ECG); L-theanine; caffeine; flavonols.',
        history        => 'Traditional Chinese Medicine: tea (cha) is described as cooling, clearing heat and promoting urination, and has been drunk daily in China and Japan for centuries.',
        culinary       => 'Prevention through daily habit: brewed green tea as a regular beverage. Its caffeine can increase night-time urination, so drink it earlier in the day.',
        reference      => 'Research: Kurahashi N, Sasazuki S, Iwasaki M, Inoue M, Tsugane S; JPHC Study Group. Green tea consumption and prostate cancer risk in Japanese men: a prospective study. Am J Epidemiol. 2008;167(1):71-77. doi:10.1093/aje/kwm249 (49,920 men: 5+ cups a day associated with lower risk of advanced prostate cancer; no association with localized cancer). Observational.',
        symptoms       => [],
    },
);

sub herbs    { return [ map { +{%$_} } @HERBS ] }
sub symptoms { return [ map { +{%$_} } @SYMPTOMS ] }

# Pure: merge seed text into an existing value. Returns the new value or undef if unchanged.
sub merge_text {
    my ( $old, $new ) = @_;
    return undef unless defined $new && length $new;
    $old //= '';
    return $new if $old !~ /\S/;
    return undef if index( $old, $MARK ) >= 0 || index( $old, $new ) >= 0;
    return "$old\n\n$MARK $new";
}

our @TEXT_FIELDS = qw(common_names parts_used constituents history culinary reference);

# Apply the seed to a DBIx::Class schema. Returns counts hashref.
sub ensure {
    my ($schema) = @_;
    my %n = map { $_ => 0 } qw(herbs_created herbs_updated symptoms_created links_created);
    $schema->txn_do( sub {
        my $SR = $schema->resultset('Ency::Symptom');
        my %sym;
        for my $s (@SYMPTOMS) {
            my $row = $SR->search( \[ 'LOWER(name) = ?', lc $s->{name} ], { rows => 1 } )->single;
            unless ($row) {
                $row = $SR->create( { sitename => 'ENCY', username_of_poster => 'system', share => 0,
                    map { $_ => $s->{$_} } grep { defined $s->{$_} } qw(name common_name description body_system) } );
                $n{symptoms_created}++;
            }
            $sym{ $s->{name} } = $row->record_id;
        }
        my $HR  = $schema->resultset('Ency::Herb');
        my $src = $HR->result_source;
        my %blank;
        for my $col ( $src->columns ) {
            next if $col eq 'record_id';
            my $i = $src->column_info($col);
            $blank{$col} = ( $i->{data_type} // '' ) =~ /int/ ? ( $i->{is_nullable} ? undef : ( $i->{default_value} // 0 ) )
                         : ( $i->{data_type} // '' ) =~ /text|char/ ? '' : undef;
        }
        my $LR = $schema->resultset('Ency::HerbSymptom');
        for my $h (@HERBS) {
            my ($binom) = $h->{botanical_name} =~ /^(\S+ \S+)/;
            my $row = $HR->search( { botanical_name => { -like => "$binom%" } }, { rows => 1, order_by => 'record_id' } )->single;
            if ( !$row ) {
                $row = $HR->create( { %blank, username_of_poster => 'system',
                    ( map { $_ => $h->{$_} } 'botanical_name', 'key_name', @TEXT_FIELDS ) } );
                $n{herbs_created}++;
            }
            else {
                my %upd;
                for my $f (@TEXT_FIELDS) {
                    my $v = merge_text( $row->get_column($f), $h->{$f} );
                    $upd{$f} = $v if defined $v;
                }
                $upd{key_name} = $h->{key_name} unless ( $row->key_name // '' ) =~ /\S/;
                if (%upd) { $row->update( \%upd ); $n{herbs_updated}++ }
            }
            for my $sname ( @{ $h->{symptoms} } ) {
                my $sid = $sym{$sname} or next;
                next if $LR->search( { herb_id => $row->record_id, symptom_id => $sid, relationship_type => $REL } )->count;
                $LR->create( { herb_id => $row->record_id, symptom_id => $sid, relationship_type => $REL,
                    notes => "$VERSION_TAG: traditional / preventive use; see herb reference for research notes." } );
                $n{links_created}++;
            }
        }
    } );
    return \%n;
}

1;
