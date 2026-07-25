package Comserv::Model::AI2::Beekeeping;
# Beekeeping voice pipeline helpers (v2, 2026-07-25).
# Reuses AI2::Transcribe for the whisper job; owns the domain logic that the
# generic transcription path needs: parse a spoken/whisper transcript into
# structured inspection observation fields, and update a voice-drafted
# inspection row from the editable in-page form.
use Moose;
use namespace::autoclean -except => [qw(try catch finally)];  # keep Try::Tiny subs (Perl 5.40)
use Try::Tiny;
use JSON;
use Comserv::Util::Logging;

extends 'Catalyst::Model';

has 'logging' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Comserv::Util::Logging->instance },
);

# Parse a spoken/whisper transcript into structured inspection observation
# fields. Ported from Controller::Apiary::_parse_voice_transcript so the v2
# transcription persistence path can reuse it without touching the v1 file.
sub parse_voice_transcript {
    my ($self, $text) = @_;
    my %fields;
    $text = lc($text // '');

    $fields{queen_seen}        = 1 if $text =~ /\b(saw|see|found|spotted)\b.*\bqueen\b/;
    $fields{queen_marked}      = 1 if $text =~ /\bqueen\b.*\bmarked\b/;
    $fields{eggs_seen}         = 1 if $text =~ /\beggs?\b/;
    $fields{larvae_seen}       = 1 if $text =~ /\blarva[e]?\b|\blarvae\b/;
    $fields{capped_brood_seen} = 1 if $text =~ /\bcapped\b.*\bbrood\b/;

    if    ($text =~ /\bvery\s+strong\b/) { $fields{population_estimate} = 'very_strong' }
    elsif ($text =~ /\bstrong\b/)        { $fields{population_estimate} = 'strong'      }
    elsif ($text =~ /\bweak\b/)          { $fields{population_estimate} = 'weak'        }
    elsif ($text =~ /\bmoderate\b/)      { $fields{population_estimate} = 'moderate'    }

    if    ($text =~ /\baggressive\b/) { $fields{temperament} = 'aggressive' }
    elsif ($text =~ /\bcalm\b|\bgentle\b/) { $fields{temperament} = 'calm' }

    if    ($text =~ /\bcritical\b/) { $fields{overall_status} = 'critical'  }
    elsif ($text =~ /\bpoor\b/)     { $fields{overall_status} = 'poor'      }
    elsif ($text =~ /\bfair\b/)     { $fields{overall_status} = 'fair'      }
    elsif ($text =~ /\bexcellent\b/) { $fields{overall_status} = 'excellent' }
    elsif ($text =~ /\bgood\b/)     { $fields{overall_status} = 'good'      }

    if ($text =~ /(\d+)\s*swarm\s*cells?/)     { $fields{swarm_cells}      = $1 }
    if ($text =~ /(\d+)\s*queen\s*cells?/)     { $fields{queen_cells}      = $1 }
    if ($text =~ /(\d+)\s*supersedure/)        { $fields{supersedure_cells} = $1 }

    $fields{feeding_done} = 1 if $text =~ /\bfed\b|\bfeeding\b|\bsyrup\b|\bfondant\b/;

    return \%fields;
}

# Update a previously drafted inspection (from the editable voice form).
# Only whitelisted observation columns are accepted; everything else is
# ignored. Returns JSON directly to the controller's response.
sub update_inspection {
    my ($self, $c) = @_;

    $c->response->content_type('application/json; charset=utf-8');

    my $id = int($c->request->param('inspection_id') || 0);
    unless ($id) {
        $c->response->status(400);
        $c->response->body(encode_json({ success => JSON::false, error => 'inspection_id required' }));
        return;
    }

    my %allowed = map { $_ => 1 } qw(
        queen_seen queen_marked eggs_seen larvae_seen capped_brood_seen
        swarm_cells queen_cells supersedure_cells population_estimate temperament
        overall_status feeding_done general_notes inspection_type
    );

    my %upd;
    for my $k (keys %allowed) {
        my $v = $c->request->param($k);
        next unless defined $v && length "$v";
        if    ($v =~ /^(true|1|yes)$/i) { $upd{$k} = 1 }
        elsif ($v =~ /^(false|0|no)$/i) { $upd{$k} = 0 }
        else                            { $upd{$k} = $v }
    }

    my $res = eval {
        my $schema = $c->model('DBEncy');
        my $row    = $schema->resultset('Inspection')->find($id);
        unless ($row) { die "inspection $id not found" }
        $row->update(\%upd) if %upd;
        { success => JSON::true, inspection_id => $id, updated => [ keys %upd ] };
    };

    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'beekeeping_update_inspection', "$@");
        $c->response->status(500);
        $c->response->body(encode_json({ success => JSON::false, error => "Update failed: $@" }));
        return;
    }

    $c->response->body(encode_json($res));
}

__PACKAGE__->meta->make_immutable;
1;
