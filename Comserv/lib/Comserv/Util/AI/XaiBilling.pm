package Comserv::Util::AI::XaiBilling;
# STUB (Oct 30 2026): read x.ai usage / billing with Shanta's x.ai MANAGEMENT key
# (user_api_keys service 'grok', key_type 'management', added by her after the schema-compare update of Result/UserApiKeys.pm).
# Not called anywhere yet. With no key it is a no-op. With a key it still does NOT call x.ai unless fetch => 1 is passed,
# so nothing happens until Shanta approves wiring it into the usage monitor.
use strict;
use warnings;
use Comserv::Util::AI::UserKeys;

our $MGMT_BASE = 'https://management-api.x.ai';   # x.ai Management API (confirm endpoint paths before enabling)

# usage($c, %o) -> { ok => 0, why => 'no_management_key' | 'not_enabled' | ... } | { ok => 1, data => {...} }
sub usage {
    my ($class, $c, %o) = @_;
    my $r = $o{key_result} || Comserv::Util::AI::UserKeys->get_user_key($c, 'grok', key_type => 'management',
                                                                          allow_owner => 1, %{ $o{lookup} || {} });
    return { ok => 0, why => 'no_management_key' } unless $r && $r->{key};
    return { ok => 0, why => 'not_enabled', key_found => 1 } unless $o{fetch};
    # TODO when approved: GET "$MGMT_BASE/auth/teams/{team_id}/..." usage/billing endpoints with the management key;
    # map the result into { day_usd, week_usd, month_usd, balance_usd } for the x.ai direct channel caps.
    return { ok => 0, why => 'not_implemented', key_found => 1 };
}

1;
