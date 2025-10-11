package Comserv::Util::SiteHelper;

use strict;
use warnings;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

# Main site fetching method
sub get_sites {
    my ($c, $site_model) = @_;
    my $sites;

    eval {
        if (lc($c->session->{SiteName}) eq 'csc') {
            $sites = $site_model->get_all_sites();
        } else {
            my $site = $site_model->get_site_details_by_name($c->session->{SiteName});
            $sites = [$site] if $site;
        }
    };
    
    if ($@) {
        Comserv::Util::Logging->instance->log_error($c, __FILE__, __LINE__, "Error fetching sites: $@");
        return [];
    }

    return $sites;
}

# Cache handling methods
our $site_cache = {};

sub clear_site_cache {
    $site_cache = {};
}

sub get_cached_sites {
    my ($c, $site_name) = @_;
    
    if (!exists $site_cache->{$site_name}) {
        my $site_model = $c->model('Site');
        $site_cache->{$site_name} = get_sites($c, $site_model);
    }
    
    return $site_cache->{$site_name};
}

1;
