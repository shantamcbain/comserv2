package Comserv::Controller::Admin::DatabaseCompare;

use strict;
use warnings;
use Moose;
use namespace::autoclean;

BEGIN { extends 'Catalyst::Controller'; }

use Comserv::Util::Logging;
use Comserv::Util::DatabaseCompare;
use Try::Tiny;

sub begin :Private {
    my ($self, $c) = @_;

    my $username = $c->session->{username} // '';
    my $roles    = $c->session->{roles}    || [];
    my @role_list = ref($roles) eq 'ARRAY' ? @$roles : split /,/, $roles;
    my $has_admin = grep { lc($_) eq 'admin' } @role_list;

    return 1 if $has_admin;
    return 1 if $username && $username ne 'Guest';

    $c->flash->{error_msg} = 'Please log in as an administrator to compare databases.';
    $c->res->redirect($c->uri_for('/user/login', { destination => $c->req->uri }));
    $c->detach;
}

sub logging {
    my ($self) = @_;
    return Comserv::Util::Logging->new;
}

sub index :Path('/admin/database_compare') :Args(0) {
    my ($self, $c) = @_;

    my $raw = $c->req->params->{db};
    my @keys = !defined $raw ? () : ref($raw) eq 'ARRAY' ? @$raw : ($raw);
    @keys = grep { defined && length } @keys;

    my @errors;
    my @sides;
    if (@keys < 2) {
        push @errors, 'Select at least two databases on the schema compare page.';
    }

    require Comserv::Model::RemoteDB;
    my $remote_db = Comserv::Model::RemoteDB->new;
    $remote_db->config({});
    my $all = $remote_db->get_all_connections;

    for my $key (@keys) {
        my ($conn_name, $database) = $key =~ /\A([A-Za-z0-9_]+)\|([A-Za-z0-9_]+)\z/;
        unless ($conn_name && $all->{$conn_name}) {
            push @errors, "Unknown database selection: $key";
            next;
        }
        my $cfg = $all->{$conn_name}{config} || {};
        my $is_pg = ($cfg->{db_type} // '') =~ /postgres/i ? 1 : 0;
        my $dbh = eval { $remote_db->get_connection(undef, $conn_name) };
        unless ($dbh) {
            push @errors, "$conn_name ($database) did not connect: "
                . ($remote_db->last_connection_error || $@ || 'login failed');
            next;
        }
        my $snap = eval {
            Comserv::Util::DatabaseCompare->snapshot($dbh, $database, $is_pg, {
                connection => $conn_name,
                host       => $cfg->{host} // '',
                port       => $cfg->{port} // '',
            });
        };
        my $err = $@;
        $dbh->disconnect;
        if ($err || !$snap) {
            push @errors, "Could not read $database via $conn_name: " . ($err || 'no snapshot');
            next;
        }
        push @sides, $snap;
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
            "Snapshot $conn_name $cfg->{host}:$cfg->{port} $database tables=" . scalar(keys %{ $snap->{tables} }));
    }

    my @pairs;
    if (@sides >= 2) {
        my $left = $sides[0];
        for my $i (1 .. $#sides) {
            my $right = $sides[$i];
            if (($left->{engine} // '') ne ($right->{engine} // '')) {
                push @errors, sprintf(
                    'Skipped %s:%s %s vs %s:%s %s — different engines.',
                    $left->{host}, $left->{port}, $left->{database},
                    $right->{host}, $right->{port}, $right->{database},
                );
                next;
            }
            push @pairs, {
                left  => $left,
                right => $right,
                diff  => Comserv::Util::DatabaseCompare->diff_pair($left, $right),
            };
        }
    }

    $c->stash(
        template => 'admin/database_compare.tt',
        errors   => \@errors,
        pairs    => \@pairs,
        selected => \@keys,
    );
}

__PACKAGE__->meta->make_immutable;

1;
