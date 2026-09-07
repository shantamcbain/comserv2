package Comserv::Util::HelpDeskWebhook;
use strict;
use warnings;
use JSON::MaybeXS qw(encode_json decode_json);
use Try::Tiny;

=head1 NAME

Comserv::Util::HelpDeskWebhook - Fire Grok Bot HelpDesk change webhooks

=head1 SYNOPSIS

  use Comserv::Util::HelpDeskWebhook;

  Comserv::Util::HelpDeskWebhook->notify_ticket_change($c,
      event  => 'ticket.created',   # ticket.created|ticket.replied|ticket.updated|ticket.mail_ingested
      change => 'created',          # created|reply|status|priority|assign|mail
      ticket => $ticket_row,        # DBIx SupportTicket (preferred)
      # OR discrete fields:
      ticket_number => 'CSC-…',
      site          => 'CSC',
      subject       => '…',
      status        => 'open',
      priority      => 'high',
      assigned_to   => 'shanta',
  );

=head1 DESCRIPTION

POSTs a small JSON event to the admin-configured HelpDesk→Grok Bot webhook
(routine C<helpdesk-ticket-change-webhook>). Failures are logged and swallowed
so ticket UI actions never block.

Config resolution (first non-empty wins):

  1. ENV HELPDESK_WEBHOOK_URL / HELPDESK_WEBHOOK_AUTH
  2. site_config keys helpdesk_webhook_url / helpdesk_webhook_auth
     for the current site, then CSC site_id=1 as shared HelpDesk defaults

HELPDESK_WEBHOOK_AUTH (or helpdesk_webhook_auth) is sent as the HTTP
Authorization header value. If it has no scheme prefix, C<Bearer > is added.

=cut

our $TIMEOUT_SEC = 3;
our $MAX_ATTEMPTS = 2;  # initial + one light retry

sub notify_ticket_change {
    my ($class, $c, %args) = @_;

    my $ok;
    try {
        $ok = $class->_notify_ticket_change_inner($c, %args);
    } catch {
        my $err = $_;
        eval {
            if ($c && eval { $c->can('log') }) {
                require Comserv::Util::Logging;
                Comserv::Util::Logging->instance->log_with_details(
                    $c, 'warn', __FILE__, __LINE__, 'notify_ticket_change',
                    "HelpDesk webhook failed (swallowed): $err"
                );
            } else {
                warn "HelpDesk webhook failed (swallowed): $err\n";
            }
        };
        $ok = 0;
    };
    return $ok ? 1 : 0;
}

sub _notify_ticket_change_inner {
    my ($class, $c, %args) = @_;

    my $cfg = $class->resolve_config($c);
    my $url = $cfg->{url} // '';
    return 0 unless $url =~ /\S/;

    my $payload = $class->build_payload(%args);
    my $json    = encode_json($payload);
    my $auth    = $cfg->{auth} // '';

    my $headers = {
        'Content-Type' => 'application/json',
        'Accept'       => 'application/json',
    };
    if ($auth =~ /\S/) {
        $auth =~ s/^\s+|\s+$//g;
        $auth = "Bearer $auth" unless $auth =~ /^(Bearer|Basic|Token)\s+/i;
        $headers->{Authorization} = $auth;
    }

    my $last_err = '';
    for my $attempt (1 .. $MAX_ATTEMPTS) {
        my ($ok, $err) = $class->_http_post($url, $json, $headers);
        if ($ok) {
            eval {
                require Comserv::Util::Logging;
                Comserv::Util::Logging->instance->log_with_details(
                    $c, 'info', __FILE__, __LINE__, 'notify_ticket_change',
                    "HelpDesk webhook OK event=" . ($payload->{event} // '')
                    . " ticket=" . ($payload->{ticket_id} // '')
                    . " attempt=$attempt"
                ) if $c;
            };
            return 1;
        }
        $last_err = $err // 'unknown';
        select(undef, undef, undef, 0.15) if $attempt < $MAX_ATTEMPTS;
    }

    eval {
        require Comserv::Util::Logging;
        Comserv::Util::Logging->instance->log_with_details(
            $c, 'warn', __FILE__, __LINE__, 'notify_ticket_change',
            "HelpDesk webhook POST failed after $MAX_ATTEMPTS attempts: $last_err"
            . " event=" . ($payload->{event} // '')
            . " ticket=" . ($payload->{ticket_id} // '')
        ) if $c;
    };
    return 0;
}

=head2 build_payload

Build the JSON-serializable event hash (also useful for unit tests).

=cut

sub build_payload {
    my ($class, %args) = @_;

    my $ticket = $args{ticket};
    my $ticket_id = $args{ticket_number}
        // $args{ticket_id}
        // ( $ticket ? eval { $ticket->ticket_number } : undef )
        // '';
    my $site = $args{site}
        // ( $ticket ? eval { $ticket->site_name } : undef )
        // '';
    my $subject = $args{subject}
        // ( $ticket ? eval { $ticket->subject } : undef )
        // '';
    my $status = $args{status}
        // ( $ticket ? eval { $ticket->status } : undef )
        // '';
    my $priority = $args{priority}
        // ( $ticket ? eval { $ticket->priority } : undef )
        // '';
    my $assigned = $args{assigned_to};
    if (!defined $assigned && $ticket) {
        $assigned = eval { $ticket->assigned_to };
    }
    $assigned //= '';

    my $event  = $args{event}  // 'ticket.updated';
    my $change = $args{change} // '';
    if (!$change) {
        $change = 'created' if $event eq 'ticket.created';
        $change = 'reply'   if $event eq 'ticket.replied';
        $change = 'mail'    if $event eq 'ticket.mail_ingested';
        $change = 'status'  if $event eq 'ticket.updated' && !$change;
    }

    my $at = $args{at} // $args{timestamp};
    if (!$at) {
        eval {
            require Comserv::Util::AppTime;
            # Prefer ISO-8601-ish UTC; AppTime default is 'YYYY-MM-DD HH:MM:SS'
            my $raw = Comserv::Util::AppTime->now_utc;
            $raw =~ s/ /T/;
            $at = $raw . 'Z';
        };
        $at ||= do {
            my @t = gmtime(time);
            sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ',
                $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
        };
    }

    return {
        event         => $event,
        ticket_id     => "$ticket_id",
        site          => "$site",
        subject       => "$subject",
        status        => "$status",
        priority      => "$priority",
        assigned_to   => "$assigned",
        change        => "$change",
        at            => "$at",
        # aliases kept for bot flexibility / idempotency keys
        ticket_number => "$ticket_id",
        timestamp     => "$at",
    };
}

=head2 resolve_config

Return C<{ url => ..., auth => ... }> from ENV and/or site_config. Never dies.

=cut

sub resolve_config {
    my ($class, $c) = @_;
    my %out = ( url => '', auth => '' );

    $out{url}  = $ENV{HELPDESK_WEBHOOK_URL}  if defined $ENV{HELPDESK_WEBHOOK_URL}  && $ENV{HELPDESK_WEBHOOK_URL}  =~ /\S/;
    $out{auth} = $ENV{HELPDESK_WEBHOOK_AUTH} if defined $ENV{HELPDESK_WEBHOOK_AUTH} && $ENV{HELPDESK_WEBHOOK_AUTH} =~ /\S/;
    # Alias: KEY → AUTH
    if (!$out{auth} && defined $ENV{HELPDESK_WEBHOOK_KEY} && $ENV{HELPDESK_WEBHOOK_KEY} =~ /\S/) {
        $out{auth} = $ENV{HELPDESK_WEBHOOK_KEY};
    }

    return \%out if $out{url} && $out{auth};  # fully from env
    return \%out unless $c && eval { $c->can('model') };

    my @site_ids;
    eval {
        my $sid = $c->session->{site_id} if $c->can('session') && $c->session;
        push @site_ids, $sid if defined $sid && $sid =~ /^\d+$/;
        # Shared HelpDesk DB — CSC (site_id=1) holds system defaults
        push @site_ids, 1;
        # Dedupe while preserving order
        my %seen;
        @site_ids = grep { !$seen{$_}++ } @site_ids;
    };

    eval {
        my $rs = $c->model('DBEncy')->resultset('SiteConfig');
        for my $sid (@site_ids) {
            if (!$out{url}) {
                my $row = $rs->find({ site_id => $sid, config_key => 'helpdesk_webhook_url' });
                $out{url} = $row->config_value if $row && defined $row->config_value && $row->config_value =~ /\S/;
            }
            if (!$out{auth}) {
                my $row = $rs->find({ site_id => $sid, config_key => 'helpdesk_webhook_auth' });
                $row ||= $rs->find({ site_id => $sid, config_key => 'helpdesk_webhook_key' });
                $out{auth} = $row->config_value if $row && defined $row->config_value && $row->config_value =~ /\S/;
            }
            last if $out{url} && $out{auth};
        }
    };

    return \%out;
}

=head2 save_config

Persist webhook URL + auth into site_config for C<$site_id> (default 1 / CSC).

=cut

sub save_config {
    my ($class, $c, %args) = @_;
    my $site_id = $args{site_id} // 1;
    my $url     = defined $args{url}  ? $args{url}  : undef;
    my $auth    = defined $args{auth} ? $args{auth} : (defined $args{key} ? $args{key} : undef);

    my $rs = $c->model('DBEncy')->resultset('SiteConfig');
    if (defined $url) {
        $rs->update_or_create({
            site_id      => $site_id,
            config_key   => 'helpdesk_webhook_url',
            config_value => $url,
        });
    }
    if (defined $auth) {
        $rs->update_or_create({
            site_id      => $site_id,
            config_key   => 'helpdesk_webhook_auth',
            config_value => $auth,
        });
    }
    return 1;
}

sub _http_post {
    my ($class, $url, $json, $headers) = @_;

    # Prefer HTTP::Tiny (already used elsewhere in Comserv)
    if (eval { require HTTP::Tiny; 1 }) {
        my $ua = HTTP::Tiny->new(timeout => $TIMEOUT_SEC);
        my $res = $ua->request('POST', $url, {
            headers => $headers,
            content => $json,
        });
        if ($res->{success}) {
            return (1, undef);
        }
        my $status = $res->{status} // 0;
        my $reason = $res->{reason} // '';
        # Treat 2xx only as success; still soft-fail on 4xx/5xx
        return (0, "HTTP $status $reason");
    }

    if (eval { require LWP::UserAgent; require HTTP::Request; 1 }) {
        my $ua  = LWP::UserAgent->new(timeout => $TIMEOUT_SEC);
        my $req = HTTP::Request->new(POST => $url);
        for my $h (keys %$headers) {
            $req->header($h => $headers->{$h});
        }
        $req->content($json);
        my $res = $ua->request($req);
        return (1, undef) if $res->is_success;
        return (0, 'HTTP ' . $res->code . ' ' . $res->message);
    }

    return (0, 'No HTTP client available (HTTP::Tiny or LWP)');
}

1;

__END__

=head1 CONFIGURE FOR SHANTA

1. Open Grok Bot HelpDesk support agent → routine C<helpdesk-ticket-change-webhook>
2. Copy Webhook URL and Webhook key / Authorization value
3. Paste into HelpDesk Admin → System Settings
   (C</HelpDesk/admin/settings>) OR set env:

     HELPDESK_WEBHOOK_URL=https://…
     HELPDESK_WEBHOOK_AUTH=Bearer …   # or raw key

=cut
