package Comserv::Util::Printing3d;

use strict;
use warnings;
use Moose;
use namespace::autoclean -except => [qw(try catch finally)];
use Try::Tiny;
use Comserv::Util::Logging;

=head1 NAME

Comserv::Util::Printing3d - thin helpers for the 3D print-farm workflow.

=head1 DESCRIPTION

Keeps new print-farm orchestration OUT of the (already large) Controller::3d.
Today: reorder_item() — queue a reprint to restock a finished-goods item.

=cut

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

sub _now { return sprintf('%04d-%02d-%02d %02d:%02d:%02d', (localtime)[5]+1900, (localtime)[4]+1, (localtime)[3], (localtime)[2], (localtime)[1], (localtime)[0]) }

# Queue a reprint of a finished-goods inventory item to restock it.
# Finds the linked active printing_3d_models row (if any) so the job carries a
# model_id; otherwise queues a standalone job named after the item. Quantity
# defaults to the item's reorder_quantity (or 1).
# Returns { ok => 1, job_id => $id } or { ok => 0, error => $msg }.
sub reorder_item {
    my ($self, $c, $item_id) = @_;

    my $sitename = $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC';
    my $schema   = $c->model('DBEncy');
    my $item;
    try { $item = $schema->resultset('Accounting::InventoryItem')->find($item_id) }
        catch { };
    return { ok => 0, error => 'Item not found.' } unless $item;

    my $model;
    try {
        $model = $schema->resultset('Printing3dModel')->search(
            { item_id => $item_id, sitename => $sitename, is_active => 1 },
            { order_by => { -asc => 'id' } },
        )->first;
    }
    catch { };

    my $qty = $item->reorder_quantity && $item->reorder_quantity > 0
            ? $item->reorder_quantity : 1;

    my $job;
    try {
        $job = $schema->resultset('Printing3dJob')->create({
            sitename            => $sitename,
            model_id            => $model ? $model->id : undef,
            item_id             => $item_id,
            user_id             => $c->session->{user_id} || 0,
            username            => $c->session->{username} || 'admin',
            status              => 'queued',
            quantity            => $qty,
            item_name           => $item->name,
            notes               => 'Reorder: restock to reorder quantity',
            inventory_reserved  => 0,
            created_at          => _now(),
        });
    }
    catch {
        my $err = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'reorder_item', "Failed to queue reorder for item $item_id: $err");
        return { ok => 0, error => "Could not queue reorder: $err" };
    };

    return { ok => 1, job_id => $job ? $job->id : undef };
}

__PACKAGE__->meta->make_immutable;
1;
