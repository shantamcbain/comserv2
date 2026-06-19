package Comserv::Util::GatewayPlan;

use strict;
use warnings;
use JSON::MaybeXS qw(decode_json encode_json);
use File::Slurp qw(read_file write_file);
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

# Lower priority number = evaluated first in the plan UI and policy docs.
# Wildcard (*) rows always sort after specific hostnames (dev, coop, etc.).
sub sort_routing_rules {
    my ( $class, $rules ) = @_;
    $rules = [] unless ref $rules eq 'ARRAY';
    return [] unless @$rules;
    my @sorted = sort {
        my $pa = $a->{priority} // 50;
        my $pb = $b->{priority} // 50;
        my $wa = ( ( $a->{hostname} // '' ) eq '*' ) ? 1 : 0;
        my $wb = ( ( $b->{hostname} // '' ) eq '*' ) ? 1 : 0;
        $pa <=> $pb || $wa <=> $wb || ( $a->{fqdn} // '' ) cmp ( $b->{fqdn} // '' );
    } @$rules;
    return \@sorted;
}

# Persist drag-reorder of policy_rules in gateway_plan.json (admin only).
sub save_policy_rules_order {
    my ( $class, $ordered_ids ) = @_;
    $ordered_ids = [] unless ref $ordered_ids eq 'ARRAY';
    my $plan = $class->load;
    my @policy = @{ $plan->{policy_rules} || $plan->{routing_rules} || [] };
    return { success => 0, error => 'No policy rules in plan' } unless @policy;

    my %by_id = map { ( $_->{id} // '' ) => $_ } grep { $_->{id} } @policy;
    my @new;
    my $prio = 10;
    for my $id (@$ordered_ids) {
        next unless $id && $by_id{$id};
        my %r = %{ $by_id{$id} };
        if ( ( $r{hostname} // '' ) eq '*' ) {
            $r{priority} = 100;
        }
        else {
            $r{priority} = $prio;
            $prio += 10;
        }
        push @new, \%r;
        delete $by_id{$id};
    }
    push @new, $_ for sort { ( $a->{fqdn} // '' ) cmp ( $b->{fqdn} // '' ) } values %by_id;

    $plan->{policy_rules}   = \@new;
    $plan->{routing_rules}  = \@new;
    $plan->{updated}        = do {
        my @t = localtime;
        sprintf '%04d-%02d-%02d', $t[5] + 1900, $t[4] + 1, $t[3];
    };

    my $file = config_path();
    eval {
        my $json = JSON::MaybeXS->new( utf8 => 1, pretty => 1, canonical => 1 )->encode($plan);
        write_file( $file, { binmode => ':utf8' }, $json );
    };
    return { success => 0, error => "$@" } if $@;
    return { success => 1, rules => \@new };
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

    my $sorted = $class->sort_routing_rules( \@enriched );
    my $out = { %$plan, routing_rules => $sorted };
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