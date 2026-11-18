package Comserv::Util::ConsignmentCountRun;

# The workflow brain for a consignment location count:
#
#   create_draft  photo (or typed text) -> DRAFT count + one line per colour.
#                 Nothing is written to stock here: the text is not proven yet.
#   update_text   the human edits the text on the verify screen; we re-parse it and
#                 refresh the draft lines.
#   discard       abandon a draft (and delete its photo).
#   apply         delegate to Comserv::Util::ConsignmentCountApply (stock, invoice,
#                 top-up, photo deletion, status=applied).
#
# Why a separate module from the vision call: the vision call may be wrong, slow or
# offline; this layer never depends on it. Drafts can also be created by hand
# (source=manual) or from Chat-with-AI (source=chat).
#
# See .hermes/plans/2026-11-05-consignment-location-count-photo.md

use strict;
use warnings;
use Try::Tiny;
use File::Path qw(make_path);
use Comserv::Util::AppTime;
use Comserv::Util::ConsignmentCount qw(parse_text format_text expected_map build_lines);
use Comserv::Util::ConsignmentCountVision;
use Comserv::Util::ConsignmentCountApply;

our $VERSION = '1.00';

my $DRAFT_DIR = 'data/consignment_counts';    # relative to the app root; gitignored

sub new {
    my ($class, %args) = @_;
    my $self = {
        root    => $args{root} || '.',
        logging => $args{logging} || eval { require Comserv::Util::Logging; Comserv::Util::Logging->instance },
        vision  => $args{vision},
        # Set only by the background worker, which has no Catalyst context to take
        # the multimodal model from. In a request the model is $c->model('Grok').
        grok    => $args{grok},
    };
    return bless $self, $class;
}

sub _log {
    my ($self, $c, $level, $msg) = @_;
    eval {
        $self->{logging}->log_with_details($c, $level, __FILE__, __LINE__,
            'ConsignmentCountRun', $msg);
    };
    return;
}

# $c is a Catalyst context in a request and a DBIx::Class schema in the worker, so
# the same run methods serve both without a fake context object.
sub _schema {
    my ($self, $c) = @_;
    return $c if ref $c && $c->isa('DBIx::Class::Schema');
    return eval { $c->model('DBEncy') };
}

sub _username {
    my ($self, $c) = @_;
    my $user = eval { $c->can('session') ? $c->session->{username} : undef };
    return $user || 'system';
}

sub _now    { return Comserv::Util::AppTime->now_utc }

sub vision {
    my ($self) = @_;
    $self->{vision} ||= Comserv::Util::ConsignmentCountVision->new(
        ($self->{grok} ? (grok => $self->{grok}) : ()),
    );
    return $self->{vision};
}

sub placement {
    my ($self, $c, $placement_id) = @_;
    my $schema = $self->_schema($c) or return undef;
    return eval {
        $schema->resultset('Accounting::InventoryConsignmentPlacement')->find(
            { 'me.id' => $placement_id, 'me.status' => 'active' },
            { prefetch => [qw(location partner item)] });
    };
}

# create_draft($c, placement_id => N, image_path => '/path/photo.jpg' | text => '2 blue, ...')
sub create_draft {
    my ($self, $c, %args) = @_;
    my $schema = $self->_schema($c) or return { ok => 0, error => 'Database not available' };
    my $user   = $self->_username($c);

    my $pl = $self->placement($c, $args{placement_id});
    return { ok => 0, error => 'Placement not found (or inactive)' } unless $pl;
    my $item = $pl->item or return { ok => 0, error => 'Placement has no item' };

    my @colours  = $pl->colour_list;
    my $expected = $pl->target_map;
    $expected = expected_map($pl->location->contents_description, \@colours)
        if (!%$expected && $pl->location);

    my ($raw_text, $engine, $confidence, $counts, $image_path, $image_mime);

    if ($args{image_path} || $args{image_b64}) {
        my $v = $self->vision;
        my $r = $v->analyse($c,
            image_path    => $args{image_path},
            image_b64     => $args{image_b64},
            mime          => $args{mime},
            item_name     => $item->name,
            location_name => ($pl->location ? $pl->location->name : 'the container'),
            colours       => \@colours,
        );
        return { ok => 0, error => ($r->{error} || 'Vision failed') } unless $r->{ok};
        $counts     = $r->{counts};
        $raw_text   = $r->{raw_text};
        $engine     = $r->{engine};
        $confidence = $r->{confidence};

        # Keep the photo as draft evidence only; it is deleted when the text is applied.
        if ($args{image_path} && -f $args{image_path}) {
            my $dir = $self->{root} . '/' . $DRAFT_DIR . '/' . $pl->location_id;
            eval { make_path($dir) unless -d $dir };
            my $ext = ($args{image_path} =~ /\.(\w+)$/) ? lc($1) : 'jpg';
            my $dest = sprintf('%s/%d_%d.%s', $dir, $pl->id, time, $ext);
            if (eval { require File::Copy; File::Copy::copy($args{image_path}, $dest) }) {
                $image_path = $dest;
                $image_mime = $args{mime} || 'image/jpeg';
            }
        }
    }
    else {
        $raw_text = $args{text} // '';
        $counts   = parse_text($raw_text, colours => \@colours);
        $engine   = 'manual';
    }

    return { ok => 0, error => 'No counts could be read from the text or the photo' }
        unless ref $counts eq 'HASH' && %$counts;

    my $rows = build_lines($counts, $expected, \@colours);
    return { ok => 0, error => 'Nothing to record' } unless @$rows;

    my ($count, $err);
    try {
        $schema->txn_do(sub {
            $count = $schema->resultset('Accounting::InventoryLocationCount')->create({
                sitename     => $pl->sitename || $self->_request_site($c),
                placement_id => $pl->id,
                location_id  => $pl->location_id,
                partner_id   => $pl->partner_id,
                item_id      => $pl->item_id,
                source       => $args{source} || ($image_path ? 'photo' : 'manual'),
                image_path   => $image_path,
                image_mime   => $image_mime,
                raw_text     => $raw_text,
                engine       => $engine,
                confidence   => $confidence,
                status       => 'draft',
                counted_by   => $user,
                counted_at   => $self->_now,
                notes        => $args{notes},
            });
            for my $r (@$rows) {
                $schema->resultset('Accounting::InventoryLocationCountLine')->create({
                    count_id       => $count->id,
                    item_id        => $pl->item_id,
                    colour         => $r->{colour},
                    qty_expected   => $r->{qty_expected},
                    qty_counted    => $r->{qty_counted},
                    qty_delta      => $r->{qty_delta},
                    filament_color => $r->{colour},
                    sort_order     => $r->{sort_order},
                });
            }
        });
    }
    catch { $err = $_ };
    return { ok => 0, error => "Could not create the draft count: $err" } if $err;

    $self->_log($c, 'info', sprintf('draft count #%d from %s: %s',
        $count->id, ($engine || 'manual'), format_text($counts, \@colours)));

    return {
        ok          => 1,
        count_id    => $count->id,
        raw_text    => format_text($counts, \@colours),
        counts      => $counts,
        lines       => $rows,
        engine      => $engine,
        confidence  => $confidence,
        image_path  => $image_path,
        placement   => { id => $pl->id, location => ($pl->location ? $pl->location->name : ''),
                         item => $item->name, partner => ($pl->partner ? $pl->partner->name : '') },
    };
}

# ---------------------------------------------------------------------------
# Photo counts run in two halves so that no web request ever waits on the model.
#
#   queue_from_photo   request thread: store the photo, create the count row with
#                      status='reading'. Milliseconds.
#   finish_from_photo  background worker: run the vision model, write raw_text +
#                      lines, flip the row to draft (or failed). Minutes are fine.
#
# Why: the app runs a single web worker, so a synchronous 7B VL inference on CPU
# froze every other request for 3.5 minutes on the first real photo (2026-11-06).
# ---------------------------------------------------------------------------


# The placement's own sitename wins. Without one, the site the request resolved
# (stash, then session). Never a hardcoded site: a guessed site files the count
# under someone else's books.
sub _request_site {
    my ($self, $c) = @_;
    return undef unless $c && ref $c && $c->can('stash');
    for my $cand (eval { $c->stash->{SiteName} }, eval { $c->session->{SiteName} }) {
        return $cand if defined $cand && $cand =~ /\S/;
    }
    return undef;
}

sub queue_from_photo {
    my ($self, $c, %args) = @_;
    my $schema = $self->_schema($c) or return { ok => 0, error => 'Database not available' };

    my $pl = $self->placement($c, $args{placement_id});
    return { ok => 0, error => 'Placement not found (or inactive)' } unless $pl;

    my $src = $args{image_path};
    return { ok => 0, error => 'No photo supplied' } unless $src && -f $src && -s $src;

    # The upload temp file dies with the request, so the photo is copied out
    # before the worker is spawned.
    my $dir = $self->{root} . '/' . $DRAFT_DIR . '/' . $pl->location_id;
    eval { make_path($dir) unless -d $dir };
    my $ext  = ($src =~ /\.(\w+)$/) ? lc($1) : 'jpg';
    my $dest = sprintf('%s/%d_%d.%s', $dir, $pl->id, time, $ext);
    unless (eval { require File::Copy; File::Copy::copy($src, $dest) }) {
        my $err = $@ || 'copy failed';
        $self->_log($c, 'error', "could not store the count photo in $dir: $err");
        return { ok => 0, error => 'Could not store the photo for reading.' };
    }

    my ($count, $err);
    try {
        $count = $schema->resultset('Accounting::InventoryLocationCount')->create({
            sitename     => $pl->sitename || $self->_request_site($c),
            placement_id => $pl->id,
            location_id  => $pl->location_id,
            partner_id   => $pl->partner_id,
            item_id      => $pl->item_id,
            source       => 'photo',
            image_path   => $dest,
            image_mime   => $args{mime} || 'image/jpeg',
            raw_text     => '',
            status       => 'reading',
            counted_by   => $self->_username($c),
            counted_at   => $self->_now,
        });
    }
    catch { $err = $_ };
    if ($err) {
        unlink $dest if -f $dest;
        $self->_log($c, 'error', "could not queue a photo count: $err");
        return { ok => 0, error => "Could not start the count: $err" };
    }

    $self->_log($c, 'info', sprintf('count #%d queued for reading (%s)',
        $count->id, $pl->location ? $pl->location->name : 'location ' . $pl->location_id));
    return { ok => 1, count_id => $count->id, placement_id => $pl->id };
}

sub finish_from_photo {
    my ($self, $c, $count_id) = @_;
    my $schema = $self->_schema($c) or return { ok => 0, error => 'Database not available' };
    my $count = eval {
        $schema->resultset('Accounting::InventoryLocationCount')->find(
            { 'me.id' => $count_id }, { prefetch => ['placement'] });
    };
    return { ok => 0, error => "Count #$count_id not found" } unless $count;
    my $status = $count->status // '';
    return { ok => 0, error => "Count #$count_id is not waiting to be read (status=$status)" }
        unless $status eq 'reading' || $status eq 'failed';

    my $pl = $count->placement;
    my @colours  = $pl ? $pl->colour_list : qw(blue yellow red green);
    my $expected = $pl ? $pl->target_map : {};
    $expected = expected_map($count->location->contents_description, \@colours)
        if (!%$expected && $count->location);

    my $image = $count->image_path;
    unless ($image && -f $image) {
        my $msg = 'The stored photo is no longer on disk.';
        eval { $count->update({ status => 'failed', notes => $msg, updated_at => $self->_now }) };
        $self->_log($c, 'error', "count #$count_id cannot be read: $msg");
        return { ok => 0, error => $msg };
    }

    my $r = $self->vision->analyse($c,
        image_path    => $image,
        mime          => $count->image_mime || 'image/jpeg',
        item_name     => ($pl && $pl->item ? $pl->item->name : ''),
        location_name => ($count->location ? $count->location->name : 'the container'),
        colours       => \@colours,
    );

    unless ($r->{ok}) {
        my $msg = $r->{error} || 'Vision failed';
        eval { $count->update({ status => 'failed', notes => substr($msg, 0, 255),
                                updated_at => $self->_now }) };
        $self->_log($c, 'error', "count #$count_id vision failed: $msg");
        return { ok => 0, error => $msg };
    }

    my $rows = build_lines($r->{counts}, $expected, \@colours);
    my $err;
    try {
        $schema->txn_do(sub {
            $count->update({
                raw_text     => format_text($r->{counts}, \@colours),
                engine       => $r->{engine},
                confidence   => $r->{confidence},
                notes        => $r->{notes},
                status       => 'draft',
                updated_at   => $self->_now,
            });
            $count->lines->delete;
            for my $row (@$rows) {
                $schema->resultset('Accounting::InventoryLocationCountLine')->create({
                    count_id       => $count->id,
                    item_id        => $count->item_id,
                    colour         => $row->{colour},
                    qty_expected   => $row->{qty_expected},
                    qty_counted    => $row->{qty_counted},
                    qty_delta      => $row->{qty_delta},
                    filament_color => $row->{colour},
                    sort_order     => $row->{sort_order},
                });
            }
        });
    }
    catch { $err = $_ };
    if ($err) {
        eval { $count->update({ status => 'failed', notes => substr("$err", 0, 255),
                                updated_at => $self->_now }) };
        $self->_log($c, 'error', "count #$count_id could not be saved: $err");
        return { ok => 0, error => "Could not save the count: $err" };
    }

    $self->_log($c, 'info', sprintf('count #%d read by %s: %s',
        $count->id, ($r->{engine} || 'vision'), format_text($r->{counts}, \@colours)));

    return {
        ok         => 1,
        count_id   => $count->id,
        raw_text   => format_text($r->{counts}, \@colours),
        counts     => $r->{counts},
        lines      => $rows,
        engine     => $r->{engine},
        confidence => $r->{confidence},
    };
}

# Replace a draft's counts with human-corrected text (the verify step).
sub update_text {
    my ($self, $c, $count_id, $text) = @_;
    my $schema = $self->_schema($c) or return { ok => 0, error => 'Database not available' };

    my $count = eval {
        $schema->resultset('Accounting::InventoryLocationCount')->find(
            { 'me.id' => $count_id }, { prefetch => ['placement'] });
    };
    return { ok => 0, error => "Count #$count_id not found" } unless $count;
    return { ok => 0, error => 'Count is not a draft' } unless ($count->status // '') eq 'draft';

    my $pl = $count->placement;
    my @colours = $pl ? $pl->colour_list : qw(blue yellow red green);
    my $expected = $pl ? $pl->target_map : {};
    $expected = expected_map($count->location->contents_description, \@colours)
        if (!%$expected && $count->location);

    my $counts = parse_text($text, colours => \@colours);
    return { ok => 0, error => 'Could not read any counts from that text' }
        unless ref $counts eq 'HASH' && %$counts;

    my $rows = build_lines($counts, $expected, \@colours);
    my $err;
    try {
        $schema->txn_do(sub {
            $count->update({ raw_text => format_text($counts, \@colours), updated_at => $self->_now });
            $count->lines->delete;
            for my $r (@$rows) {
                $schema->resultset('Accounting::InventoryLocationCountLine')->create({
                    count_id       => $count->id,
                    item_id        => $count->item_id,
                    colour         => $r->{colour},
                    qty_expected   => $r->{qty_expected},
                    qty_counted    => $r->{qty_counted},
                    qty_delta      => $r->{qty_delta},
                    filament_color => $r->{colour},
                    sort_order     => $r->{sort_order},
                });
            }
        });
    }
    catch { $err = $_ };
    return { ok => 0, error => "Could not save the corrected text: $err" } if $err;

    return { ok => 1, count_id => $count->id, raw_text => format_text($counts, \@colours), lines => $rows };
}

# Abandon a draft and drop its photo.
sub discard {
    my ($self, $c, $count_id) = @_;
    my $schema = $self->_schema($c) or return { ok => 0, error => 'Database not available' };
    my $count = eval { $schema->resultset('Accounting::InventoryLocationCount')->find($count_id) };
    return { ok => 0, error => "Count #$count_id not found" } unless $count;
    return { ok => 0, error => 'Only a draft can be discarded' } unless ($count->status // '') eq 'draft';

    my %upd = (status => 'void', updated_at => $self->_now);
    if (my $p = $count->image_path) {
        unlink $p if (defined $p && length $p && -f $p);
        $upd{image_deleted_at} = $self->_now;
    }
    $count->update(\%upd);
    return { ok => 1, count_id => $count->id };
}

# The human ticked "text is correct": apply it.
sub apply {
    my ($self, $c, $count_id, %opts) = @_;
    my $apply = Comserv::Util::ConsignmentCountApply->new(logging => $self->{logging});
    return $apply->apply($c, $count_id, %opts);
}

1;
