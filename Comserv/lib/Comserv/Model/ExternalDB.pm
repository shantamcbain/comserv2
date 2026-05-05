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

sub ncbi_search_taxonomy {
    my ($self, $c, $scientific_name) = @_;
    return undef unless $scientific_name;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'ncbi_search_taxonomy',
        "Searching NCBI taxonomy for: $scientific_name");

    my $name_enc = $scientific_name;
    $name_enc =~ s/ /+/g;
    my $search_url = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi"
                   . "?db=taxonomy&term=${name_enc}[SCINAME]&retmode=json&retmax=5";

    my $search = $self->_get_json($c, $search_url);
    return undef unless $search && ref $search->{esearchresult}{idlist} eq 'ARRAY';

    my @ids = @{ $search->{esearchresult}{idlist} };
    return undef unless @ids;

    my $tax_id = $ids[0];
    return $self->ncbi_fetch_by_tax_id($c, $tax_id);
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

    my $result = {
        ncbi_tax_id     => $tax_id,
        scientific_name => $rec->{scientificname} // '',
        common_name     => $rec->{commonname}     // '',
        kingdom         => $rec->{kingdom}         // '',
        phylum          => $rec->{phylum}          // '',
        class_name      => $rec->{class}           // '',
        order_name      => $rec->{order}           // '',
        family_name     => $rec->{family}          // '',
        organism_type   => _infer_type($rec),
        source_url      => "https://www.ncbi.nlm.nih.gov/Taxonomy/Browser/wwwtax.cgi?id=$tax_id",
        db_name         => 'NCBI',
    };

    if ($result->{scientific_name} =~ /^(\S+)\s+(.+)$/) {
        $result->{genus}   = $1;
        $result->{species} = $2;
    }

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
    my ($rec) = @_;
    my $lineage = lc($rec->{lineage} // '');
    return 'plant'     if $lineage =~ /viridiplantae|embryophyta|plantae/;
    return 'fungus'    if $lineage =~ /fungi/;
    return 'bacterium' if $lineage =~ /bacteria/;
    return 'virus'     if $lineage =~ /viruses/;
    return 'insect'    if $lineage =~ /insecta/;
    return 'bird'      if $lineage =~ /aves/;
    return 'fish'      if $lineage =~ /actinopterygii/;
    return 'amphibian' if $lineage =~ /amphibia/;
    return 'reptile'   if $lineage =~ /reptilia/;
    return 'human'     if ($rec->{taxid} // 0) == 9606;
    return 'mammal'    if $lineage =~ /mammalia/;
    return 'animal';
}

__PACKAGE__->meta->make_immutable;
1;
