package Comserv::Controller::3d;
use Moose;
use namespace::autoclean;

BEGIN { extends 'Catalyst::Controller'; }

sub index :Path :Args(0) {
    my ( $self, $c ) = @_;
    $c->session->{MailServer} = "http://webmail.usbm.ca";

    my $sitename = $c->session->{SiteName} || '3d';
    my @items;
    eval {
        @items = $c->model('DBEncy')->resultset('InventoryItem')->search(
            { sitename => $sitename, status => 'active' },
            {
                prefetch => 'stock_levels',
                order_by => ['category', 'name'],
                rows     => 12,
            }
        );
    };

    $c->stash(
        shop_items => \@items,
        sitename   => $sitename,
        template   => '3d/index.tt',
    );
}

__PACKAGE__->meta->make_immutable;

1;
