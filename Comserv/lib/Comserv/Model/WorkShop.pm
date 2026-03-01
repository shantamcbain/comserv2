package Comserv::Model::WorkShop;
use Moose;
use namespace::autoclean;
use Comserv::Util::AdminAuth;

extends 'Catalyst::Model';

sub get_active_workshops {
    my ($self, $c) = @_;

    my $rs = $c->model('DBEncy')->resultset('WorkShop');
    my @workshops;
    my $error;
    eval {
        my $admin_auth = Comserv::Util::AdminAuth->new();
        my $admin_type = $admin_auth->get_admin_type($c);
        my $is_admin   = ($admin_type eq 'csc' || $admin_type eq 'special' || $admin_type eq 'standard');

        my $filter = {
            -or => [
                { 'me.date' => { '>=' => DateTime->today->ymd } },
                { 'me.date' => undef },
            ]
        };

        # Admins see all non-draft upcoming workshops; everyone else sees only published
        $filter->{'me.status'} = $is_admin ? { '!=' => 'draft' } : 'published';

        @workshops = $rs->search(
            $filter,
            { order_by => { -asc => 'me.date' }, prefetch => 'creator' }
        );
    };
    $error = "Error fetching active workshops: $@" if $@;
    return (\@workshops, $error);
}

sub get_workshop_by_id {
    my ($self, $c, $id) = @_;
    my $workshop;
    eval { $workshop = $c->model('DBEncy')->resultset('WorkShop')->find($id) };
    return $@ ? (undef, "Error fetching workshop: $@") : ($workshop, undef);
}

sub get_past_workshops {
    my ($self, $c) = @_;

    my $rs = $c->model('DBEncy')->resultset('WorkShop');
    my @workshops;
    my $error;
    eval {
        my $admin_auth = Comserv::Util::AdminAuth->new();
        my $admin_type = $admin_auth->get_admin_type($c);
        my $is_admin   = ($admin_type eq 'csc' || $admin_type eq 'special' || $admin_type eq 'standard');

        my $filter = { 'me.date' => { '<' => DateTime->today->ymd } };
        $filter->{'me.status'} = { '!=' => 'draft' } unless $is_admin;

        @workshops = $rs->search(
            $filter,
            { order_by => { -desc => 'me.date' }, prefetch => 'creator' }
        );
    };
    $error = "Error fetching past workshops: $@" if $@;
    return (\@workshops, $error);
}

__PACKAGE__->meta->make_immutable;

1;
