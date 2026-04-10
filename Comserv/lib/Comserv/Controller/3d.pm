package Comserv::Controller::3d;
use Moose;
use namespace::autoclean;
use POSIX qw(strftime);
use Comserv::Util::Logging;

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

BEGIN { extends 'Catalyst::Controller'; }

=head1 NAME

Comserv::Controller::3d - Catalyst Controller for the 3D Printing add-on module

=head1 DESCRIPTION

Site add-on module providing 3D printing services:
- Browse/search 3D model files (FileManager DB, NFS local, AI/web search)
- Order prints from the farm
- Print queue and job management
- Printer farm administration
- Inventory integration for filaments and supplies

Module name in site_modules table: C<printing_3d>

=cut

sub _sitename {
    my ($self, $c) = @_;
    return $c->stash->{SiteName} || $c->session->{SiteName} || 'default';
}

sub _schema {
    my ($self, $c) = @_;
    return $c->model('DBEncy');
}

sub _now {
    return strftime('%Y-%m-%d %H:%M:%S', localtime);
}

sub _is_module_enabled {
    my ($self, $c) = @_;
    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);
    my $mod;
    eval {
        $mod = $schema->resultset('SiteModule')->find(
            { sitename => $sitename, module_name => 'printing_3d', enabled => 1 }
        );
    };
    return $mod ? 1 : 0;
}

sub _require_module {
    my ($self, $c) = @_;
    unless ($self->_is_module_enabled($c)) {
        $c->stash->{error_msg} = '3D Printing module is not enabled for this site.';
        $c->stash->{template}  = '3d/index.tt';
        $c->detach;
    }
}

sub _require_admin {
    my ($self, $c) = @_;
    my $roles = $c->session->{roles} || [];
    my $is_admin = grep { $_ eq 'admin' } @{$roles};
    unless ($is_admin) {
        $c->stash->{error_msg} = 'Admin access required.';
        $c->res->redirect($c->uri_for('/3d'));
        $c->detach;
    }
}

# ============================================================
# Landing page
# ============================================================

sub index :Path :Args(0) {
    my ($self, $c) = @_;

    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
        "3D Printing index for site=$sitename");

    my ($model_count, $printer_count, $my_open_jobs) = (0, 0, 0);
    my $module_enabled = $self->_is_module_enabled($c);

    if ($module_enabled) {
        eval {
            $model_count   = $schema->resultset('Printing3dModel')->search(
                { sitename => $sitename, is_active => 1 })->count;
            $printer_count = $schema->resultset('Printing3dPrinter')->search(
                { sitename => $sitename, status => 'idle' })->count;
            if ($c->session->{user_id}) {
                $my_open_jobs = $schema->resultset('Printing3dJob')->search(
                    { sitename => $sitename, user_id => $c->session->{user_id},
                      status   => { -in => ['queued','assigned','printing'] } }
                )->count;
            }
        };
    }

    $c->stash(
        sitename       => $sitename,
        module_enabled => $module_enabled,
        model_count    => $model_count,
        printer_count  => $printer_count,
        my_open_jobs   => $my_open_jobs,
        template       => '3d/index.tt',
    );
}

# ============================================================
# Browse / Search 3D Models
# ============================================================

sub browse :Path('/3d/browse') :Args(0) {
    my ($self, $c) = @_;
    $self->_require_module($c);

    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);
    my $q        = $c->req->params->{q} || '';

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'browse',
        "3D browse site=$sitename q=$q");

    my @models;
    eval {
        my %search = (sitename => $sitename, is_active => 1);
        if ($q) {
            $search{-or} = [
                { name        => { -like => "%$q%" } },
                { description => { -like => "%$q%" } },
                { tags        => { -like => "%$q%" } },
            ];
        }
        @models = $schema->resultset('Printing3dModel')->search(
            \%search,
            { order_by => { -asc => 'name' } }
        )->all;
    };
    push @{$c->stash->{debug_errors}}, "Error loading models: $@" if $@;

    $c->stash(
        sitename => $sitename,
        models   => \@models,
        q        => $q,
        template => '3d/browse.tt',
    );
}

# ============================================================
# Model Detail
# ============================================================

sub model_detail :Path('/3d/model') :Args(1) {
    my ($self, $c, $id) = @_;
    $self->_require_module($c);

    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);

    my $model;
    eval {
        $model = $schema->resultset('Printing3dModel')->find(
            { id => $id, sitename => $sitename }
        );
    };
    unless ($model) {
        $c->stash->{error_msg} = 'Model not found.';
        $c->res->redirect($c->uri_for('/3d/browse'));
        $c->detach;
    }

    my @filaments;
    eval {
        @filaments = $schema->resultset('InventoryItem')->search(
            { sitename => $sitename, category => '3d_filament', status => 'active' }
        )->all;
    };

    $c->stash(
        sitename  => $sitename,
        model     => $model,
        filaments => \@filaments,
        template  => '3d/model_detail.tt',
    );
}

# ============================================================
# Order a Print
# ============================================================

sub order :Path('/3d/order') :Args(0) {
    my ($self, $c) = @_;
    $self->_require_module($c);

    unless ($c->session->{user_id}) {
        $c->flash->{error_msg} = 'You must be logged in to order a print.';
        $c->res->redirect($c->uri_for('/user/login',
            { destination => $c->req->uri }));
        $c->detach;
    }

    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);

    if ($c->req->method eq 'POST') {
        my $model_id       = $c->req->params->{model_id};
        my $filament_color = $c->req->params->{filament_color} || '';
        my $filament_type  = $c->req->params->{filament_type}  || '';
        my $quantity       = $c->req->params->{quantity}        || 1;
        my $notes          = $c->req->params->{notes}           || '';

        my $model;
        eval {
            $model = $schema->resultset('Printing3dModel')->find(
                { id => $model_id, sitename => $sitename, is_active => 1 }
            );
        };
        unless ($model) {
            $c->stash->{error_msg} = 'Invalid model selected.';
            $c->res->redirect($c->uri_for('/3d/browse'));
            $c->detach;
        }

        my ($idle_printer, $job_status);
        eval {
            $idle_printer = $schema->resultset('Printing3dPrinter')->search(
                { sitename => $sitename, status => 'idle' },
                { rows => 1 }
            )->first;
        };

        $job_status = $idle_printer ? 'assigned' : 'queued';

        my $job;
        eval {
            $job = $schema->resultset('Printing3dJob')->create({
                sitename       => $sitename,
                model_id       => $model_id,
                user_id        => $c->session->{user_id},
                username       => $c->session->{username} || '',
                printer_id     => $idle_printer ? $idle_printer->id : undef,
                status         => $job_status,
                filament_color => $filament_color,
                filament_type  => $filament_type,
                quantity       => $quantity,
                notes          => $notes,
                created_at     => _now(),
            });

            if ($idle_printer) {
                $idle_printer->update({
                    status         => 'printing',
                    current_job_id => $job->id,
                    updated_at     => _now(),
                });
            }
        };
        if ($@) {
            $c->stash->{error_msg} = "Error creating print job: $@";
        } else {
            my $msg = $job_status eq 'assigned'
                ? 'Print job created and assigned to a printer!'
                : 'Print job queued — a printer will be assigned when one is available.';
            $c->flash->{success_msg} = $msg;
            $c->res->redirect($c->uri_for('/3d/my_orders'));
            $c->detach;
        }
    }

    my $model_id = $c->req->params->{model_id};
    my $model;
    eval {
        $model = $schema->resultset('Printing3dModel')->find(
            { id => $model_id, sitename => $sitename }
        ) if $model_id;
    };

    $c->stash(
        sitename => $sitename,
        model    => $model,
        template => '3d/order.tt',
    );
}

# ============================================================
# My Orders
# ============================================================

sub my_orders :Path('/3d/my_orders') :Args(0) {
    my ($self, $c) = @_;
    $self->_require_module($c);

    unless ($c->session->{user_id}) {
        $c->res->redirect($c->uri_for('/user/login',
            { destination => $c->req->uri }));
        $c->detach;
    }

    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);

    my @jobs;
    eval {
        @jobs = $schema->resultset('Printing3dJob')->search(
            { sitename => $sitename, user_id => $c->session->{user_id} },
            { prefetch => ['model', 'printer'], order_by => { -desc => 'created_at' } }
        )->all;
    };
    push @{$c->stash->{debug_errors}}, "Error loading jobs: $@" if $@;

    $c->stash(
        sitename => $sitename,
        jobs     => \@jobs,
        template => '3d/my_orders.tt',
    );
}

# ============================================================
# Admin — Print Queue
# ============================================================

sub queue :Path('/3d/queue') :Args(0) {
    my ($self, $c) = @_;
    $self->_require_module($c);
    $self->_require_admin($c);

    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);

    if ($c->req->method eq 'POST') {
        my $job_id     = $c->req->params->{job_id};
        my $printer_id = $c->req->params->{printer_id};
        my $action     = $c->req->params->{action} || '';

        eval {
            my $job = $schema->resultset('Printing3dJob')->find($job_id);
            if ($job && $action eq 'assign' && $printer_id) {
                my $printer = $schema->resultset('Printing3dPrinter')->find($printer_id);
                if ($printer) {
                    $job->update({
                        printer_id => $printer_id,
                        status     => 'assigned',
                    });
                    $printer->update({
                        status         => 'printing',
                        current_job_id => $job_id,
                        updated_at     => _now(),
                    });
                }
            } elsif ($job && $action eq 'complete') {
                my $printer = $job->printer;
                $job->update({ status => 'completed', completed_at => _now() });
                if ($printer) {
                    $printer->update({
                        status         => 'idle',
                        current_job_id => undef,
                        updated_at     => _now(),
                    });
                }
            } elsif ($job && $action eq 'cancel') {
                my $printer = $job->printer;
                $job->update({ status => 'cancelled', completed_at => _now() });
                if ($printer && $printer->current_job_id == $job_id) {
                    $printer->update({
                        status         => 'idle',
                        current_job_id => undef,
                        updated_at     => _now(),
                    });
                }
            }
        };
        $c->res->redirect($c->uri_for('/3d/queue'));
        $c->detach;
    }

    my (@queued_jobs, @active_jobs, @idle_printers);
    eval {
        @queued_jobs = $schema->resultset('Printing3dJob')->search(
            { sitename => $sitename, status => { -in => ['queued'] } },
            { prefetch => ['model', 'printer'], order_by => { -asc => 'created_at' } }
        )->all;
        @active_jobs = $schema->resultset('Printing3dJob')->search(
            { sitename => $sitename, status => { -in => ['assigned', 'printing'] } },
            { prefetch => ['model', 'printer'], order_by => { -asc => 'created_at' } }
        )->all;
        @idle_printers = $schema->resultset('Printing3dPrinter')->search(
            { sitename => $sitename, status => 'idle' }
        )->all;
    };

    $c->stash(
        sitename      => $sitename,
        queued_jobs   => \@queued_jobs,
        active_jobs   => \@active_jobs,
        idle_printers => \@idle_printers,
        template      => '3d/queue.tt',
    );
}

# ============================================================
# Admin — Printer Farm
# ============================================================

sub printers :Path('/3d/printers') :Args(0) {
    my ($self, $c) = @_;
    $self->_require_module($c);
    $self->_require_admin($c);

    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);

    if ($c->req->method eq 'POST') {
        my $action = $c->req->params->{action} || '';
        eval {
            if ($action eq 'add') {
                $schema->resultset('Printing3dPrinter')->create({
                    sitename        => $sitename,
                    name            => $c->req->params->{name},
                    model           => $c->req->params->{model} || '',
                    status          => 'idle',
                    nozzle_diameter => $c->req->params->{nozzle_diameter} || '0.40',
                    bed_size        => $c->req->params->{bed_size} || '',
                    notes           => $c->req->params->{notes} || '',
                    created_at      => _now(),
                });
            } elsif ($action eq 'update_status') {
                my $printer = $schema->resultset('Printing3dPrinter')->find(
                    $c->req->params->{printer_id}
                );
                $printer->update({
                    status     => $c->req->params->{status},
                    updated_at => _now(),
                }) if $printer;
            } elsif ($action eq 'delete') {
                my $printer = $schema->resultset('Printing3dPrinter')->find(
                    $c->req->params->{printer_id}
                );
                $printer->delete if $printer && $printer->status eq 'idle';
            }
        };
        $c->res->redirect($c->uri_for('/3d/printers'));
        $c->detach;
    }

    my @printers;
    eval {
        @printers = $schema->resultset('Printing3dPrinter')->search(
            { sitename => $sitename },
            { order_by => { -asc => 'name' } }
        )->all;
    };

    $c->stash(
        sitename => $sitename,
        printers => \@printers,
        template => '3d/printers.tt',
    );
}

# ============================================================
# Admin Dashboard
# ============================================================

sub admin :Path('/3d/admin') :Args(0) {
    my ($self, $c) = @_;
    $self->_require_module($c);
    $self->_require_admin($c);

    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);

    my ($total_printers, $idle_printers, $total_models, $queued_jobs, $active_jobs);
    eval {
        $total_printers = $schema->resultset('Printing3dPrinter')->search(
            { sitename => $sitename })->count;
        $idle_printers  = $schema->resultset('Printing3dPrinter')->search(
            { sitename => $sitename, status => 'idle' })->count;
        $total_models   = $schema->resultset('Printing3dModel')->search(
            { sitename => $sitename, is_active => 1 })->count;
        $queued_jobs    = $schema->resultset('Printing3dJob')->search(
            { sitename => $sitename, status => 'queued' })->count;
        $active_jobs    = $schema->resultset('Printing3dJob')->search(
            { sitename => $sitename, status => { -in => ['assigned','printing'] } })->count;
    };

    $c->stash(
        sitename        => $sitename,
        total_printers  => $total_printers  || 0,
        idle_printers   => $idle_printers   || 0,
        total_models    => $total_models    || 0,
        queued_jobs     => $queued_jobs     || 0,
        active_jobs     => $active_jobs     || 0,
        template        => '3d/admin.tt',
    );
}

# ============================================================
# Deeper Search — AI / Web Search
# BLOCKED: Requires AIChatSystem extension (see todo for BLOCK-1)
# When AIChatSystem adds /ai/search_3d_models, wire this action.
# ============================================================

sub search_deeper :Path('/3d/search_deeper') :Args(0) {
    my ($self, $c) = @_;
    $self->_require_module($c);

    my $sitename = $self->_sitename($c);
    my $q        = $c->req->params->{q} || '';

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'search_deeper',
        "Deeper search requested site=$sitename q=$q");

    # BLOCKED: AIChatSystem endpoint /ai/search_3d_models not yet implemented.
    # When ready, forward request to AI controller for web/AI search.
    # Track progress in Todo: "AIChatSystem: Add /ai/search_3d_models for 3D file web search"
    $c->stash(
        sitename        => $sitename,
        q               => $q,
        search_results  => [],
        feature_pending => 1,
        pending_message => 'AI-powered web search for 3D models is coming soon. '
            . 'This feature is pending the AIChatSystem web-search extension.',
        template => '3d/browse.tt',
    );
}

=encoding utf8

=head1 AUTHOR

Shanta McBain

=head1 LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

__PACKAGE__->meta->make_immutable;

1;
