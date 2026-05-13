package Comserv::Model::ExternalDB;

use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use Try::Tiny;
use JSON;
use LWP::UserAgent;
extends 'Catalyst::Model';

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance },
);

has '_ua' => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        my $ua = LWP::UserAgent->new(
            timeout => 15,
            agent   => 'ENCY-Encyclopedia/1.0 (comserv; educational)',
        );
        $ua->default_header('Accept' => 'application/json');
        return $ua;
    },
);

sub COMPONENT {
    my ($class, $app, $args) = @_;
    return $class->new({ %{ $args // {} } });
}

sub _get_json {
    my ($self, $c, $url) = @_;
    my $resp = $self->_ua->get($url);
    unless ($resp->is_success) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_get_json',
            "HTTP GET failed: " . $resp->status_line . " for $url");
        return undef;
    }
    my $data = eval { decode_json($resp->decoded_content) };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_get_json',
            "JSON decode error for $url: $@");
        return undef;
    }
    return $data;
}

sub _get_xml {
    my ($self, $c, $url) = @_;
    my $ua = LWP::UserAgent->new(timeout => 15,
        agent => 'ENCY-Encyclopedia/1.0 (comserv; educational)');
    my $resp = $ua->get($url);
    unless ($resp->is_success) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_get_xml',
            "HTTP GET failed: " . $resp->status_line . " for $url");
        return undef;
    }
    return $resp->decoded_content;
}

sub _parse_ncbi_lineage_xml {
    my ($self, $xml) = @_;
    return {} unless $xml;
    my %rank_map;
    while ($xml =~ m{<Taxon>\s*<TaxId>[^<]*</TaxId>\s*<ScientificName>([^<]+)</ScientificName>\s*<Rank>([^<]+)</Rank>}g) {
        my ($name, $rank) = ($1, $2);
        $rank = lc($rank);
        next if $rank eq 'no rank' || $rank eq 'cellular root' || $rank eq 'clade';
        $rank_map{$rank} = $name;
    }
    return \%rank_map;
}

sub ncbi_search_taxonomy {
    my ($self, $c, $scientific_name) = @_;
    return undef unless $scientific_name;

    my @candidates = $self->_clean_botanical_name($scientific_name);

    for my $name (@candidates) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'ncbi_search_taxonomy',
            "Searching NCBI taxonomy for: $name");

        my $name_enc = $name;
        $name_enc =~ s/ /+/g;
        my $search_url = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi"
                       . "?db=taxonomy&term=${name_enc}[SCINAME]&retmode=json&retmax=5";

        my $search = $self->_get_json($c, $search_url);
        next unless $search && ref $search->{esearchresult}{idlist} eq 'ARRAY';

        my @ids = @{ $search->{esearchresult}{idlist} };
        next unless @ids;

        my $result = $self->ncbi_fetch_by_tax_id($c, $ids[0]);
        if ($result) {
            $result->{searched_as} = $name if $name ne $scientific_name;
            return $result;
        }
        select(undef, undef, undef, 0.35);
    }

    return undef;
}

sub _clean_botanical_name {
    my ($self, $name) = @_;
    $name =~ s/^\s+|\s+$//g;

    my @candidates;
    push @candidates, $name;

    my $clean = $name;

    $clean =~ s/,\s*\(.*\)//g;
    $clean =~ s/\s*,.*$//;

    $clean =~ s/\s+var\b.*$//i;
    $clean =~ s/\s+subsp\b.*$//i;
    $clean =~ s/\s+ssp\b.*$//i;
    $clean =~ s/\s+f\.\s+\S+.*$//i;

    $clean =~ s/\s*\([^)]*\)\s*/ /g;
    $clean =~ s/\s+[A-Z][a-z]+\.\s+.*$//;
    $clean =~ s/\s+[A-Z]\.\s+.*$//;
    $clean =~ s/\s+L\.\s*$//i;
    $clean =~ s/\s+Mill\.\s*$//i;
    $clean =~ s/\s{2,}/ /g;
    $clean =~ s/^\s+|\s+$//g;

    push @candidates, $clean if $clean ne $name;

    if ($clean =~ /^(\S+\s+\S+)/) {
        my $two_words = $1;
        push @candidates, $two_words if $two_words ne $clean && $two_words ne $name;
    }

    my %seen;
    return grep { !$seen{$_}++ && /\S/ } @candidates;
}

sub ncbi_fetch_by_tax_id {
    my ($self, $c, $tax_id) = @_;
    return undef unless $tax_id && $tax_id =~ /^\d+$/;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'ncbi_fetch_by_tax_id',
        "Fetching NCBI taxonomy ID: $tax_id");

    my $url = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi"
            . "?db=taxonomy&id=$tax_id&retmode=json";

    my $data = $self->_get_json($c, $url);
    return undef unless $data && ref $data->{result} eq 'HASH';

    my $rec = $data->{result}{$tax_id} // {};
    return undef unless $rec->{scientificname};

    my $xml_url = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi"
                . "?db=taxonomy&id=$tax_id&retmode=xml";
    my $xml = $self->_get_xml($c, $xml_url);
    my $lineage_rank = $self->_parse_ncbi_lineage_xml($xml);
    select(undef, undef, undef, 0.25);

    my $result = {
        ncbi_tax_id     => $tax_id,
        scientific_name => $rec->{scientificname} // '',
        common_name     => $rec->{commonname}     // '',
        kingdom         => $lineage_rank->{kingdom}  // $lineage_rank->{superkingdom} // '',
        phylum          => $lineage_rank->{phylum}   // '',
        class_name      => $lineage_rank->{class}    // '',
        order_name      => $lineage_rank->{order}    // '',
        family_name     => $lineage_rank->{family}   // '',
        genus           => $rec->{genus}             // $lineage_rank->{genus} // '',
        organism_type   => _infer_type($rec, $lineage_rank),
        source_url      => "https://www.ncbi.nlm.nih.gov/Taxonomy/Browser/wwwtax.cgi?id=$tax_id",
        db_name         => 'NCBI',
    };

    if ($result->{scientific_name} =~ /^\S+\s+(.+)$/) {
        $result->{species} = $rec->{species} // $1;
    }
    $result->{genus} ||= (split /\s+/, $result->{scientific_name})[0] // '';

    return $result;
}

sub pubchem_lookup_by_name {
    my ($self, $c, $name) = @_;
    return undef unless $name;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'pubchem_lookup_by_name',
        "PubChem lookup for: $name");

    my $name_enc = $name;
    $name_enc =~ s/ /%20/g;

    my $url = "https://pubchem.ncbi.nlm.nih.gov/rest/pug/compound/name/"
            . "${name_enc}/JSON?MaxRecords=1";

    my $data = $self->_get_json($c, $url);
    return undef unless $data;

    my $compound = eval { $data->{PC_Compounds}[0] };
    return undef unless $compound;

    my $cid = $compound->{id}{id}{cid};
    return undef unless $cid;

    my $props = {};
    for my $prop (@{ $compound->{props} // [] }) {
        my $label = $prop->{urn}{label}     // '';
        my $name  = $prop->{urn}{name}      // '';
        my $val   = $prop->{value}{sval}
               // $prop->{value}{ival}
               // $prop->{value}{fval}
               // '';
        $props->{$label} = $val if $val ne '';
    }

    return {
        pubchem_cid => $cid,
        iupac_name  => $props->{'IUPAC Name'}   // '',
        formula     => $props->{'Molecular Formula'} // '',
        inchi       => $props->{'InChI'}         // '',
        source_url  => "https://pubchem.ncbi.nlm.nih.gov/compound/$cid",
        db_name     => 'PubChem',
    };
}

sub disease_ontology_lookup {
    my ($self, $c, $term) = @_;
    return undef unless $term;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'disease_ontology_lookup',
        "Disease Ontology lookup for: $term");

    my $enc = $term;
    $enc =~ s/ /+/g;
    my $url = "https://www.ebi.ac.uk/ols4/api/search?q=${enc}&ontology=doid&rows=5&format=json";

    my $data = $self->_get_json($c, $url);
    return undef unless $data;

    my @docs = @{ $data->{response}{docs} // [] };
    return undef unless @docs;

    my $best = $docs[0];
    return {
        doid        => $best->{obo_id}   // '',
        label       => $best->{label}    // '',
        description => ($best->{description} // [])->[0] // '',
        source_url  => "https://disease-ontology.org/term/" . ($best->{obo_id} // ''),
        db_name     => 'DOID',
    };
}

sub save_external_id {
    my ($self, $c, $ency_schema, $entity_type, $entity_id, $ext) = @_;
    return unless $ext && $ext->{db_name} && $ext->{external_id} || $ext->{ncbi_tax_id}
                                                                  || $ext->{pubchem_cid}
                                                                  || $ext->{doid};

    my $ext_id_val = $ext->{external_id} // $ext->{ncbi_tax_id} // $ext->{pubchem_cid} // $ext->{doid};
    return unless $ext_id_val;

    try {
        $ency_schema->resultset('Ency::ExternalID')->update_or_create(
            {
                entity_type => $entity_type,
                entity_id   => $entity_id,
                db_name     => $ext->{db_name},
            },
            {
                key         => 'unique_entity_db',
                external_id => "$ext_id_val",
                source_url  => $ext->{source_url} // '',
                retrieved_at => \'NOW()',
                notes       => $ext->{notes} // '',
            },
        );
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'save_external_id',
            "Saved $ext->{db_name} ID $ext_id_val for $entity_type/$entity_id");
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'save_external_id',
            "Failed to save external ID: $_");
    };
}

sub get_external_ids {
    my ($self, $c, $ency_schema, $entity_type, $entity_id) = @_;
    my @ids;
    try {
        @ids = $ency_schema->resultset('Ency::ExternalID')->search(
            { entity_type => $entity_type, entity_id => $entity_id },
            { order_by    => 'db_name' }
        )->all;
    };
    return \@ids;
}

sub _infer_type {
    my ($rec, $lineage_rank) = @_;
    $lineage_rank //= {};

    my $division = lc($rec->{division}        // '');
    my $gendiv   = lc($rec->{genbankdivision} // '');

    return 'human'     if ($rec->{taxid} // 0) == 9606;

    return 'plant'     if $division =~ /eudicot|monocot|gymnosperm|angiosperm|land plant|green plant|streptophyt|embryophyt|charophyt/;
    return 'plant'     if $division =~ /^(green algae)$/;
    return 'fungus'    if $division =~ /fung|ascomycet|basidiomycet|lichen/;
    return 'bacterium' if $division =~ /bacter|archaea/;
    return 'virus'     if $division =~ /virus/;
    return 'insect'    if $division =~ /insect|dipter|lepidopter|coleopt|hymenopter/;
    return 'bird'      if $division =~ /bird/;
    return 'reptile'   if $division =~ /reptil|lizard|snake|turtle|croc/;
    return 'amphibian' if $division =~ /amphibi|frog|toad|salamand/;
    return 'fish'      if $division =~ /fish|teleost|shark|ray/;
    return 'mammal'    if $division =~ /mammal|primate|rodent|carnivore|ungulate|bat|whale/;

    return 'plant'     if $gendiv =~ /plants? and fungi/i && $division !~ /fung/;
    return 'plant'     if $gendiv =~ /^plants?$/i;
    return 'fungus'    if $gendiv =~ /^fungi$/i || ($gendiv =~ /plants? and fungi/i && $division =~ /fung/);
    return 'bacterium' if $gendiv =~ /bacter/i;
    return 'virus'     if $gendiv =~ /virus/i;
    return 'bird'      if $gendiv =~ /bird/i;
    return 'mammal'    if $gendiv =~ /mammal|primate|rodent/i;
    return 'fish'      if $gendiv =~ /fish/i;

    my $kingdom = lc($lineage_rank->{kingdom} // $lineage_rank->{superkingdom} // '');
    return 'plant'     if $kingdom =~ /viridiplantae/;
    return 'fungus'    if $kingdom =~ /fungi/;
    return 'bacterium' if $kingdom =~ /bacteria/;
    return 'virus'     if $kingdom =~ /virus/;

    return 'animal';
}

sub gbif_lookup_by_name {
    my ($self, $c, $scientific_name) = @_;
    return undef unless $scientific_name;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'gbif_lookup_by_name',
        "GBIF lookup for: $scientific_name");

    my $enc  = $scientific_name;
    $enc     =~ s/ /+/g;
    my $match_url = "https://api.gbif.org/v1/species/match?name=$enc&strict=false";
    my $match = $self->_get_json($c, $match_url);
    return undef unless $match && $match->{usageKey};

    my $gbif_id = $match->{usageKey};

    my $media_url = "https://api.gbif.org/v1/species/$gbif_id/media?limit=5";
    my $media_data = $self->_get_json($c, $media_url);
    select(undef, undef, undef, 0.2);

    my @images;
    for my $item (@{ $media_data->{results} // [] }) {
        next unless ($item->{type} // '') eq 'StillImage';
        my $url = $item->{identifier} // '';
        next unless $url;
        next if $url =~ m{plos|plosone|pensoft|zenodo|researchgate|academia\.edu
                         |doi\.org|pubmed|ncbi\.nlm|figshare|springer|elsevier
                         |wiley|nature\.com/articles|sciencedirect|bioone
                         |\.pdf|graph|chart|figure}xi;
        next if ($item->{publisher} // '') =~ m{journal|proceedings|society|press}i;
        push @images, {
            url           => $url,
            thumbnail_url => $url,
            license       => $item->{license}       // '',
            rights_holder => $item->{rightsHolder}  // '',
            caption       => $item->{title}         // $item->{description} // '',
            source        => 'GBIF',
        };
        last if @images >= 3;
    }

    return {
        gbif_id     => $gbif_id,
        images      => \@images,
        source_url  => "https://www.gbif.org/species/$gbif_id",
    };
}

sub wikipedia_summary {
    my ($self, $c, $scientific_name) = @_;
    return undef unless $scientific_name;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'wikipedia_summary',
        "Wikipedia lookup for: $scientific_name");

    my $title = $scientific_name;
    $title =~ s/ /_/g;

    my $api_base = 'https://en.wikipedia.org/w/api.php';
    my $enc      = $title;
    $enc         =~ s/([^A-Za-z0-9_~.-])/sprintf('%%%02X', ord($1))/ge;

    my $url = "$api_base?action=query&prop=extracts|pageimages&exintro=1"
            . "&titles=$enc&format=json&pithumbsize=800&redirects=1";

    my $data = $self->_get_json($c, $url);
    return undef unless $data;

    my ($page) = values %{ $data->{query}{pages} // {} };
    return undef unless $page && ($page->{pageid} // -1) > 0;

    my $extract = $page->{extract} // '';
    $extract =~ s/<[^>]+>//g;
    $extract =~ s/\n{3,}/\n\n/g;
    $extract =~ s/^\s+|\s+$//g;

    my ($description, $habitat) = ('', '');
    if ($extract) {
        my @paras = split /\n\n+/, $extract;
        $description = $paras[0] // '';
        for my $p (@paras[1..$#paras]) {
            if ($p =~ /habitat|distribution|range|found in|native to|grow/i) {
                $habitat = $p;
                last;
            }
        }
        $description = substr($description, 0, 2000) if length($description) > 2000;
        $habitat     = substr($habitat,     0, 1000) if length($habitat)     > 1000;
    }

    my $image_url = '';
    if (my $thumb = $page->{thumbnail}) {
        $image_url = $thumb->{source} // '';
    }

    return {
        description  => $description,
        habitat      => $habitat,
        image_url    => $image_url,
        wiki_title   => $page->{title} // $scientific_name,
        wiki_url     => "https://en.wikipedia.org/wiki/$title",
        source       => 'Wikipedia',
    };
}

__PACKAGE__->meta->make_immutable;
1;
