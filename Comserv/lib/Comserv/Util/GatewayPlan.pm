package Comserv::Util::GatewayPlan;

use strict;
use warnings;
use JSON::MaybeXS qw(decode_json encode_json);
use File::Slurp qw(read_file);
use Catalyst::Utils;

sub config_path {
    return Catalyst::Utils::home('Comserv') . '/config/infrastructure/gateway_plan.json';
}

sub load {
    my ($class) = @_;
    my $file = config_path();
    return $class->_default_plan unless -f $file;
    my $data = eval { decode_json(read_file($file)) };
    return $class->_default_plan if $@ || ref $data ne 'HASH';
    $data->{routing_rules} = [] unless ref $data->{routing_rules} eq 'ARRAY';
    if (!@{ $data->{routing_rules} } && ref $data->{policy_rules} eq 'ARRAY') {
        $data->{routing_rules} = $data->{policy_rules};
    }
    return $data;
}

sub _default_plan {
    return {
        version       => '0',
        routing_rules => [],
        tool_roles    => [],
    };
}

# Compare planned Unbound rules against live OPNsense host overrides.
sub enrich_with_drift {
    my ($class, $plan, $opnsense_status) = @_;
    $plan ||= $class->load;
    my $rules = $plan->{routing_rules} || [];
    my @dns_rows;
    if (ref $opnsense_status eq 'HASH' && ref $opnsense_status->{dns_hosts} eq 'HASH') {
        @dns_rows = @{ $opnsense_status->{dns_hosts}{rows} || [] };
    }

    my @enriched;
    for my $rule (@$rules) {
        my %entry = %$rule;
        $entry{dns_layer} //= '';
        if ($entry{dns_layer} eq 'unbound') {
            my ($match) = grep { _dns_row_matches($_, \%entry) } @dns_rows;
            if ($match) {
                my $expected = $entry{lan_ip} // '';
                my $actual   = $match->{server} // '';
                if ($expected && $actual eq $expected) {
                    $entry{sync_status} = 'ok';
                    $entry{sync_detail} = "Unbound → $actual";
                } elsif ($expected) {
                    $entry{sync_status} = 'drift';
                    $entry{sync_detail} = "Unbound has $actual; plan expects $expected";
                } else {
                    $entry{sync_status} = 'ok';
                    $entry{sync_detail} = "Unbound → $actual";
                }
            } else {
                $entry{sync_status} = $entry{phase} && $entry{phase} eq 'planned' ? 'planned' : 'missing';
                $entry{sync_detail} = 'No matching Unbound host override';
            }
        } elsif ($entry{dns_layer} eq 'cloudflare' || $entry{dns_layer} eq 'cloudflare_only') {
            $entry{sync_status} = $entry{phase} && $entry{phase} eq 'active' ? 'external' : 'planned';
            $entry{sync_detail} = $entry{dns_layer} eq 'cloudflare_only'
                ? 'Public DNS only — LAN covered by wildcard'
                : 'Managed in Application DNS (Cloudflare)';
        } else {
            $entry{sync_status} = 'n/a';
            $entry{sync_detail} = '';
        }
        push @enriched, \%entry;
    }

    my $out = { %$plan, routing_rules => \@enriched };
    $out->{drift_count} = scalar grep {
        $_->{sync_status} && $_->{sync_status} =~ /^(missing|drift)$/
    } @enriched;
    return $out;
}

sub _dns_row_matches {
    my ($row, $rule) = @_;
    return 0 unless ref $row eq 'HASH' && ref $rule eq 'HASH';
    my $rh = $row->{hostname} // '';
    my $rd = $row->{domain}   // '';
    my $eh = $rule->{hostname} // '';
    my $ed = $rule->{domain}   // '';
    return ($rh eq $eh && $rd eq $ed);
}

sub doc_links {
    my ($class, $c) = @_;
    return [
        {
            title => 'Gateway Plan (full guide)',
            uri   => $c->uri_for('/Documentation/system/GatewayPlan'),
            icon  => 'fa-route',
        },
        {
            title => 'Server Room IP Registry',
            uri   => $c->uri_for('/Documentation/system/Server_Room_IP_Registry'),
            icon  => 'fa-network-wired',
        },
        {
            title => 'OPNsense VM setup',
            uri   => $c->uri_for('/Documentation/proxmox/opnsense_vm_proxmox_k83_setup'),
            icon  => 'fa-shield-alt',
        },
        {
            title => 'Application DNS (Cloudflare)',
            uri   => $c->uri_for('/admin/dns'),
            icon  => 'fa-cloud',
        },
        {
            title => 'Cloudflare integration doc',
            uri   => $c->uri_for('/Documentation/CloudflareIntegration'),
            icon  => 'fa-book',
        },
        {
            title => 'Docker deployment pipeline',
            uri   => $c->uri_for('/admin/docker_containers'),
            icon  => 'fa-docker',
        },
    ];
}

1;