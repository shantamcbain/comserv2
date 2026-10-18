use strict;
use warnings;
use Test::More;
use Comserv::Model::ENCYModel;
my $m = 'Comserv::Model::ENCYModel';
is_deeply( [ map { s/^\s+|\s+$//gr } $m->_split_terms('common: Nausea, Vomiting, Constipation (codeine, morphine); serious: Hepatotoxicity (acetaminophen overdose)') ],
    [ 'common: Nausea', 'Vomiting', 'Constipation (codeine, morphine)', 'serious: Hepatotoxicity (acetaminophen overdose)' ], 'paren-aware split' );
my %want = (
    'common: Nausea'                                   => 'Nausea',
    'Constipation (codeine'                            => 'Constipation',
    'Constipation (codeine, morphine)'                 => 'Constipation',
    'serious: Hepatotoxicity (acetaminophen overdose)' => 'Hepatotoxicity',
    'Respiratory depression (codeine'                  => 'Respiratory depression',
    'and back'                                         => 'back',
    'and c. pneumothrorax'                             => 'pneumothrorax',
    'b. Flayil Chse'                                   => 'Flayil Chse',
    'an enlarged prostate'                             => 'enlarged prostate',
    '[object Object]'                                  => '',
    'object Object'                                    => '',
    'Allergic reactions'                               => 'Allergic reactions',
    'Dependence or withdrawal (codeine'                => 'Dependence or withdrawal',
);
is( $m->_draft_clean_term( 'Symptom', $_ ), $want{$_}, "clean '$_'" ) for sort keys %want;
done_testing;
