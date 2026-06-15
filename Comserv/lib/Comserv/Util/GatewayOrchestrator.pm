package Comserv::Util::GatewayOrchestrator;

use strict;
use warnings;
use Comserv::Util::HostingAccount;
use Comserv::Util::GatewayPlan;
use Comserv::Util::Opnsense;
use Socket;
use Try::Tiny;

# Dynamic gateway orchestration: rules from hosting_accounts + policy templates.
# Avoids growing static route/DNS lists — accounts drive customer hostnames.

sub targets {
    my ($class, $plan) = @_;
    $plan ||= Comserv::Util::GatewayPlan->load;
    my $t = $plan->{targets} || {};
    return {
        gateway_lan        => $t->{gateway_lan}        || '192.168.1.1',
        production_lan     => $t->{production_lan}     || '192.168.1.126',
        production_zt      => $t->{production_zt}      || '172.30.50.206',
        dev_workstation_lan => $t->{dev_workstation_lan} || '192.168.1.199',
        dev_workstation_zt  => $t->{dev_workstation_zt}  || '172.30.131.126',
        dev_port           => $t->{dev_port}           || 3001,
        prod_port          => $t->{prod_port}          || 5000,
        wildcard_zones     => $t->{wildcard_zones}     || ['computersystemconsulting.ca'],
    };
}

sub fqdn_parts {
    my ($fqdn) = @_;
    $fqdn = lc($fqdn // '');
    $fqdn =~ s/\.$//;
    return () unless $fqdn =~ /\./;
    my ($zone) = $fqdn =~ /([^.]+\.[^.]+)$/;
    return () unless $zone;
    my $host = $fqdn;
    if ($fqdn eq $zone) {
        $host = '';
    } else {
        $host =~ s/\.\Q$zone\E\z//;
    }
    return ($host, $zone);
}

sub _unbound_rows {
    my ($opnsense_status) = @_;
    return [] unless ref $opnsense_status eq 'HASH'
        && ref $opnsense_status->{dns_hosts} eq 'HASH';
    return @{ $opnsense_status->{dns_hosts}{rows} || [] };
}

sub _find_unbound {
    my ($rows, $host, $domain) = @_;
    ($host) = defined $host ? $host : '';
    for my $r (@$rows) {
        next unless ref $r eq 'HASH';
        my $rh = $r->{hostname} // '';
        my $rd = $r->{domain}   // '';
        return $r if $rh eq $host && $rd eq $domain;
    }
    return;
}

sub _has_wildcard {
    my ($rows, $domain) = @_;
    return _find_unbound($rows, '*', $domain);
}

# Policy templates from gateway_plan.json (wildcard, dev patterns — not per customer).
sub policy_rules {
    my ($class, $plan) = @_;
    $plan ||= Comserv::Util::GatewayPlan->load;
    return @{ $plan->{policy_rules} || $plan->{routing_rules} || [] };
}

# One rule per active hosting account — generated at runtime, not stored in JSON.
sub hosting_rules {
    my ($class, $c) = @_;
    my @rules;
    my $tgt = $class->targets;
    return \@rules unless $c;

    try {
        my @accounts = $c->model('DBEncy')->resultset('Accounting::HostingAccount')->search(
            { status => 'active' },
        )->all;

        for my $ha (@accounts) {
            my $fqdn = Comserv::Util::HostingAccount::resolve_hostname($ha);
            next unless $fqdn && $fqdn =~ /\./;
            next unless Comserv::Util::HostingAccount::is_public_dns_domain($fqdn);
            my ($host, $zone) = fqdn_parts($fqdn);
            next unless $zone;

            my $is_dev = defined $host && $host eq 'dev';
            my $is_csc_dev = $is_dev && $zone eq 'computersystemconsulting.ca';
            my $lan_ip = $is_csc_dev ? $tgt->{gateway_lan}
                : ($is_dev ? $tgt->{dev_workstation_lan} : $tgt->{production_lan});
            my $zt_ip  = $is_dev ? $tgt->{dev_workstation_zt}  : $tgt->{production_zt};
            my $port   = $is_csc_dev ? 80 : ($is_dev ? $tgt->{dev_port} : $tgt->{prod_port});

            my $needs_unbound = 1;
            if ($is_dev) {
                $needs_unbound = 1;
            } elsif ($host eq '') {
                $needs_unbound = 1;
            } elsif (grep { $_ eq $zone } @{ $tgt->{wildcard_zones} }) {
                $needs_unbound = 0;    # *.zone covers shared prod subdomains on LAN
            }

            push @rules, {
                id         => 'ha-' . ($ha->id // 0),
                source     => 'hosting_account',
                label      => 'Hosted: ' . ($ha->sitename // '?'),
                hostname   => $host // '',
                domain     => $zone,
                fqdn       => $fqdn,
                lan_ip     => $lan_ip,
                zt_ip      => $zt_ip,
                port       => $port,
                dns_layer  => $needs_unbound ? 'unbound' : 'cloudflare_only',
                public_dns => 'cloudflare',
                ssl        => $is_dev ? 'dev_self_signed' : 'haproxy_acme',
                priority   => $is_dev ? 10 : 80,
                phase      => 'active',
                plan_slug  => $ha->plan_slug // '',
                hosting_id => $ha->id,
                notes      => 'Auto from hosting_accounts #' . ($ha->id // ''),
            };
        }
    } catch {
        # DB unavailable during audit — skip dynamic rules
    };

    return \@rules;
}

sub merged_plan {
    my ($class, $c, $opnsense_status) = @_;
    my $base = Comserv::Util::GatewayPlan->load;
    my @policy  = $class->policy_rules($base);
    my $hosting = $c ? $class->hosting_rules($c) : [];
    my %seen;
    my @all;
    for my $r (@policy, @$hosting) {
        my $key = ($r->{fqdn} // '') . '|' . ($r->{source} // 'policy');
        next if $seen{$key}++;
        push @all, $r;
    }
    my $merged = { %$base, routing_rules => \@all };
    return Comserv::Util::GatewayPlan->enrich_with_drift($merged, $opnsense_status);
}

# Admin warnings: misroutes, wildcard shadowing, missing overrides.
sub audit {
    my ($class, $c, $opnsense_status, $plan) = @_;
    $plan ||= $class->merged_plan($c, $opnsense_status);
    my @warnings;
    my $tgt   = $class->targets($plan);
    my @rows  = _unbound_rows($opnsense_status);

    my $add = sub {
        my (%w) = @_;
        $w{severity} ||= 'warn';
        $w{fix}      ||= '';
        push @warnings, \%w;
    };

    # --- Known infra dev patterns (always check) ---
    for my $spec (
        { fqdn => 'dev.beemaster.ca', host => 'dev', domain => 'beemaster.ca', ip => $tgt->{dev_workstation_lan}, via_gateway => 0 },
        {
            fqdn        => 'dev.computersystemconsulting.ca',
            host        => 'dev',
            domain      => 'computersystemconsulting.ca',
            ip          => $tgt->{gateway_lan},
            backend_ip  => $tgt->{dev_workstation_lan},
            via_gateway => 1,
        },
    ) {
        my $wc = _has_wildcard(\@rows, $spec->{domain});
        my $ov = _find_unbound(\@rows, $spec->{host}, $spec->{domain});
        if ($wc && !$ov) {
            $add->(
                severity => 'error',
                code     => 'wildcard_shadows_dev',
                title    => "$spec->{fqdn} is caught by wildcard → production",
                detail   => "Unbound has *.$spec->{domain} but no dev override. "
                          . "dev.* resolves to production ($tgt->{production_lan}), not the workstation ($tgt->{dev_workstation_lan}).",
                fix        => $spec->{via_gateway}
                    ? "Apply dev gateway: Unbound → $tgt->{gateway_lan}, HAProxy :80 → $tgt->{dev_workstation_lan}:$tgt->{dev_port}"
                    : "Add Unbound host override: hostname=dev, domain=$spec->{domain}, IP=$tgt->{dev_workstation_lan}",
                fqdn       => $spec->{fqdn},
                fix_domain => $spec->{domain},
                fix_action => $spec->{via_gateway} ? 'fix_dev_gateway' : 'fix_dev_unbound',
            );
        } elsif ($ov && ($ov->{server} // '') ne $spec->{ip}) {
            my $expect_label = $spec->{via_gateway}
                ? "gateway $spec->{ip} (HAProxy → $spec->{backend_ip}:$tgt->{dev_port})"
                : "workstation $spec->{ip}";
            $add->(
                severity => 'error',
                code     => 'dev_wrong_target',
                title    => "$spec->{fqdn} Unbound points to wrong IP",
                detail   => "Override has " . ($ov->{server} // '?') . "; expected $expect_label.",
                fix      => $spec->{via_gateway}
                    ? "Apply dev gateway (Unbound + HAProxy) for dev.$spec->{domain}"
                    : "Edit Unbound override for dev.$spec->{domain} → $spec->{ip}",
                fqdn       => $spec->{fqdn},
                fix_domain => $spec->{domain},
                fix_action => $spec->{via_gateway} ? 'fix_dev_gateway' : undef,
            );
        } elsif (!$ov && !$wc) {
            $add->(
                severity => 'warn',
                code     => 'dev_override_missing',
                title    => "No Unbound entry for $spec->{fqdn}",
                detail   => $spec->{via_gateway}
                    ? 'LAN clients need dev → gateway for portless HTTP.'
                    : 'LAN clients may not resolve dev to the workstation.',
                fix      => $spec->{via_gateway}
                    ? "Apply dev gateway for dev.$spec->{domain}"
                    : "Add Unbound: dev + $spec->{domain} → $tgt->{dev_workstation_lan}",
                fqdn       => $spec->{fqdn},
                fix_domain => $spec->{domain},
                fix_action => $spec->{via_gateway} ? 'fix_dev_gateway' : undef,
            );
        }
    }

    # --- Per hosting account checks ---
    if ($c) {
        try {
            my @accounts = $c->model('DBEncy')->resultset('Accounting::HostingAccount')->search(
                { status => { -in => [qw(active pending)] } },
            )->all;

            for my $ha (@accounts) {
                my $fqdn = Comserv::Util::HostingAccount::resolve_hostname($ha);
                next unless $fqdn;
                my ($host, $zone) = fqdn_parts($fqdn);
                next unless $zone;

                my $site_ok = eval {
                    $c->model('DBEncy')->resultset('SiteDomain')->search({ domain => $fqdn })->count;
                } || 0;
                unless ($site_ok) {
                    $add->(
                        severity => 'warn',
                        code     => 'no_sitedomain',
                        title    => 'Hosting #' . $ha->id . " ($fqdn): no SiteDomain row",
                        detail   => 'Site provisioning may be incomplete.',
                        fix      => 'Run Site Provisioning for sitename ' . ($ha->sitename // ''),
                        fqdn     => $fqdn,
                        hosting_id => $ha->id,
                    );
                }

                if (($ha->status // '') eq 'active') {
                    my $rule = _find_unbound(\@rows, $host // '', $zone);
                    my $is_dev = defined $host && $host eq 'dev';
                    my $wc = _has_wildcard(\@rows, $zone);
                    if ($is_dev && $wc && !$rule) {
                        $add->(
                            severity => 'error',
                            code     => 'hosting_dev_shadowed',
                            title    => "Active hosting $fqdn blocked by wildcard",
                            detail   => "*.$zone sends all names to production; dev needs its own override.",
                            fix      => "Add Unbound dev.$zone → $tgt->{dev_workstation_lan}",
                            fqdn     => $fqdn,
                            hosting_id => $ha->id,
                        );
                    }
                }
            }
        } catch { };
    }

    # --- Drift from merged plan ---
    for my $rule (@{ $plan->{routing_rules} || [] }) {
        next unless ($rule->{sync_status} // '') =~ /^(missing|drift)$/;
        next if ($rule->{phase} // '') eq 'planned';
        $add->(
            severity => ($rule->{sync_status} eq 'drift' ? 'error' : 'warn'),
            code     => 'plan_' . ($rule->{sync_status} // 'drift'),
            title    => ($rule->{label} // $rule->{fqdn} // 'Rule') . ': ' . ($rule->{sync_status} // ''),
            detail   => $rule->{sync_detail} // '',
            fix      => $rule->{dns_layer} eq 'unbound'
                ? 'Add or fix Unbound override on OPNsense (or use Apply from gateway plan when enabled)'
                : 'Check Cloudflare Application DNS',
            fqdn     => $rule->{fqdn} // '',
        );
    }

    # --- Optional resolution probe on the Comserv host (when Socket DNS works) ---
    try {
        for my $probe (
            { name => 'dev.beemaster.ca', want => $tgt->{dev_workstation_lan} },
            { name => 'dev.computersystemconsulting.ca', want => $tgt->{gateway_lan} },
        ) {
            my $ip = _resolve_ipv4($probe->{name});
            next unless $ip;
            if ($ip eq $tgt->{production_lan}) {
                $add->(
                    severity => 'error',
                    code     => 'resolve_points_prod',
                    title    => "This server resolves $probe->{name} → production LAN",
                    detail   => "$probe->{name} → $ip (expected $probe->{want} for dev).",
                    fix      => 'Fix Unbound override or local DNS; wildcard may be winning.',
                    fqdn     => $probe->{name},
                );
            } elsif ($probe->{name} eq 'dev.computersystemconsulting.ca'
                && $ip eq $tgt->{dev_workstation_lan}) {
                $add->(
                    severity => 'warn',
                    code     => 'resolve_points_workstation_not_gateway',
                    title    => 'dev.csc resolves to workstation — :80 will not reach Starman',
                    detail   => "$probe->{name} → $ip; use gateway $tgt->{gateway_lan} for portless HTTP "
                              . "(HAProxy forwards to :$tgt->{dev_port}).",
                    fix      => 'Apply dev gateway (Unbound + HAProxy) on OPNsense.',
                    fqdn     => $probe->{name},
                    fix_domain => 'computersystemconsulting.ca',
                    fix_action => 'fix_dev_gateway',
                );
            }
        }
    } catch { };

    # --- Public DNS for dev.csc (Apply Unbound does not change Cloudflare) ---
    my $dev_csc = 'dev.computersystemconsulting.ca';
    my $pub_ips = _public_dns_ips($dev_csc);
    if (@$pub_ips && !grep { $_ eq $tgt->{dev_workstation_lan} || $_ eq $tgt->{dev_workstation_zt} } @$pub_ips) {
        $add->(
            severity => 'warn',
            code     => 'dev_public_dns_not_workstation',
            title    => "$dev_csc public DNS does not point at the workstation",
            detail   => 'Unbound LAN override may be correct, but browsers using Cloudflare/public DNS see: '
                      . join(', ', @$pub_ips)
                      . " — not $tgt->{dev_workstation_lan}. "
                      . 'https://dev.csc hits Cloudflare/production, not Starman :3001 on the workstation.',
            fix      => 'For remote dev: add Cloudflare A record dev → ZT IP (grey cloud) or use '
                      . "http://$tgt->{dev_workstation_lan}:$tgt->{dev_port}/ on LAN. "
                      . 'Edit in Application DNS.',
            fqdn       => $dev_csc,
            fix_domain => 'computersystemconsulting.ca',
        );
    }

    my $error_count = scalar grep { ($_->{severity} // '') eq 'error' } @warnings;
    my $warn_count  = scalar grep { ($_->{severity} // '') eq 'warn' } @warnings;

    my $diag = $class->diagnostics($tgt, \@rows, $opnsense_status);

    return {
        warnings    => \@warnings,
        error_count => $error_count,
        warn_count  => $warn_count,
        diagnostics => $diag,
    };
}

sub _public_dns_ips {
    my ($name) = @_;
    my @ips;
    try {
        my $packed = gethostbyname($name);
        if ($packed) {
            push @ips, inet_ntoa($packed);
        }
    } catch { };
    return \@ips;
}

# Quick gateway vs workstation checks for admin UI.
sub diagnostics {
    my ($class, $tgt, $unbound_rows, $opnsense_status) = @_;
    $tgt ||= $class->targets;
    $unbound_rows ||= [];

    my $ws_url = "http://$tgt->{dev_workstation_lan}:$tgt->{dev_port}/health";
    my $gw_url = "http://dev.computersystemconsulting.ca/health";
    my $ws_ok  = 0;
    my $gw_ok  = 0;
    my $ws_detail = 'not checked';
    my $gw_detail = 'not checked';
    if (eval { require LWP::UserAgent; 1 }) {
        my $ua = LWP::UserAgent->new(timeout => 6);
        my $res = $ua->get($ws_url);
        $ws_ok = $res->is_success ? 1 : 0;
        $ws_detail = $res->code ? "HTTP " . $res->code : ($res->status_line || 'failed');
        my $gres = $ua->get($gw_url);
        $gw_ok = $gres->is_success ? 1 : 0;
        $gw_detail = $gres->code ? "HTTP " . $gres->code : ($gres->status_line || 'failed');
    }

    my $dev_unbound = _find_unbound($unbound_rows, 'dev', 'computersystemconsulting.ca');
    my $dev_csc_pub = _public_dns_ips('dev.computersystemconsulting.ca');
    my $hap = _haproxy_dev_csc_status($opnsense_status);

    return {
        workstation_health_url => $ws_url,
        workstation_ok         => $ws_ok,
        workstation_detail     => $ws_detail,
        gateway_dev_url        => 'http://dev.computersystemconsulting.ca/',
        gateway_health_url     => $gw_url,
        gateway_proxy_ok       => $gw_ok,
        gateway_proxy_detail   => $gw_detail,
        unbound_dev_csc        => $dev_unbound ? ($dev_unbound->{server} // '') : '',
        unbound_dev_csc_ok     => ($dev_unbound && ($dev_unbound->{server} // '') eq $tgt->{gateway_lan}) ? 1 : 0,
        unbound_dev_csc_want   => $tgt->{gateway_lan},
        haproxy_dev_csc_ok     => $hap->{ok} ? 1 : 0,
        haproxy_dev_csc_detail => $hap->{detail} // '',
        public_dev_csc_ips     => $dev_csc_pub,
        lan_dev_url            => "http://dev.computersystemconsulting.ca/",
        direct_dev_url         => "http://$tgt->{dev_workstation_lan}:$tgt->{dev_port}/",
        note                   => 'LAN dev.csc should resolve to the gateway (' . $tgt->{gateway_lan}
                                . ') and HAProxy forwards :80 → workstation :' . $tgt->{dev_port}
                                . '. If the gateway probe fails but direct :3001 works, open :3001 on the workstation for 192.168.1.1 '
                                . '(sudo script/firewalld_laptop_access.sh). Public https://dev.csc still uses Cloudflare.',
    };
}

sub _haproxy_dev_csc_status {
    my ($opnsense_status) = @_;
    return { ok => 0, detail => 'HAProxy status not loaded' }
        unless ref $opnsense_status eq 'HASH';
    my $hap = $opnsense_status->{haproxy};
    return { ok => 0, detail => 'HAProxy not queried' } unless ref $hap eq 'HASH';

    my @checks = (
        [ frontends => 'Comserv_Dev_HTTP' ],
        [ backends  => 'Comserv_Dev_Backend' ],
        [ servers   => 'WorkstationDev3001' ],
        [ acls      => 'DevCSC_host' ],
        [ actions   => 'DevCSC_use_backend' ],
    );
    my @missing;
    for my $check (@checks) {
        my ($key, $name) = @$check;
        my $rows = ref $hap->{$key} eq 'HASH' ? $hap->{$key}{rows} : [];
        next if _haproxy_find_row($rows, $name);
        push @missing, $name;
    }
    if (@missing) {
        return { ok => 0, detail => 'Missing HAProxy objects: ' . join(', ', @missing) };
    }
    my $svc = ref $hap->{service} eq 'HASH' ? ($hap->{service}{status} // '') : '';
    return { ok => ($svc eq 'running' ? 1 : 0), detail => "HAProxy $svc" };
}

sub _haproxy_find_row {
    my ($rows, $name) = @_;
    for my $r (@{ $rows || [] }) {
        return $r if ref $r eq 'HASH' && ($r->{name} // '') eq $name;
    }
    return;
}

sub _resolve_ipv4 {
    my ($name) = @_;
    return try {
        my $packed = gethostbyname($name);
        return unless $packed;
        return inet_ntoa($packed);
    } catch {
        return;
    };
}

# Ordered provisioning after site + Cloudflare (called from SiteProvisioning).
sub provision_for_hosting {
    my ($class, $c, $args, $steps) = @_;
    $args ||= {};
    $steps ||= [];
    my $domain    = $args->{domain}    || '';
    my $plan_slug = $args->{plan_slug}  || '';
    my $tgt       = $class->targets;

    my ($host, $zone) = fqdn_parts($domain);
    unless ($zone) {
        push @$steps, 'Gateway: invalid domain — skipped OPNsense steps.';
        return { success => 0, skipped => 1 };
    }

    my $api = _opnsense_client($c);
    unless ($api) {
        push @$steps, 'Gateway: OPNsense API not configured — add overrides manually.';
        return { success => 0, skipped => 1 };
    }

    my $is_dev     = defined $host && $host eq 'dev';
    my $is_private = $plan_slug =~ /private|dedicated|vm/i;

    if ($is_private) {
        push @$steps, 'Gateway: private/dedicated plan — VM + OPNsense NAT/firewall (automated in Phase 4; provision VM first).';
        return { success => 1, deferred => 1 };
    }

    if ($is_dev && $zone eq 'computersystemconsulting.ca') {
        my $gw = $api->ensure_dev_csc_gateway({
            gateway_ip   => $tgt->{gateway_lan},
            backend_ip   => $tgt->{dev_workstation_lan},
            backend_port => $tgt->{dev_port},
            domain       => $zone,
        });
        if ($gw->{success}) {
            push @$steps, "Gateway dev.$zone: Unbound → $tgt->{gateway_lan}, HAProxy → :$tgt->{dev_port}.";
        } else {
            push @$steps, 'Gateway dev.csc HAProxy failed: ' . ($gw->{error} // 'unknown');
        }
    } elsif ($is_dev || ($host ne '' && _needs_specific_unbound($host, $zone, $tgt))) {
        my $ip = $is_dev ? $tgt->{dev_workstation_lan} : $tgt->{production_lan};
        my $res = $api->add_host_override({
            hostname    => $host,
            domain      => $zone,
            ip          => $ip,
            description => "Comserv auto: $domain (hosting provision)",
        });
        if ($res->{success}) {
            $api->reconfigure_unbound;
            push @$steps, "Gateway Unbound: added $domain → $ip.";
        } else {
            my $err = $res->{error} // 'unknown';
            if ($err =~ /already|duplicate|exists/i) {
                push @$steps, "Gateway Unbound: $domain already present (ok).";
            } else {
                push @$steps, "Gateway Unbound: failed for $domain — $err";
            }
        }
    } else {
        push @$steps, "Gateway Unbound: skipped — *.$zone wildcard covers $domain on LAN.";
    }

    return { success => 1 };
}

sub _needs_specific_unbound {
    my ($host, $zone, $tgt) = @_;
    return 1 if $host eq 'dev';
    return 0 if grep { $_ eq $zone } @{ $tgt->{wildcard_zones} };
    return 1;
}

sub _opnsense_client {
    my ($c) = @_;
    my $config_file = Catalyst::Utils::home('Comserv') . '/config/infrastructure/opnsense.json';
    return unless -f $config_file;
    my $cfg = eval {
        require JSON::MaybeXS;
        JSON::MaybeXS::decode_json(do { local $/; open my $f, '<', $config_file; <$f> });
    };
    return unless $cfg && $cfg->{host};
    return Comserv::Util::Opnsense->new($cfg);
}

1;