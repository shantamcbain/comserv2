package Comserv::Controller::Admin::RolePermissions;

use Moose;
use namespace::autoclean;
use Digest::SHA qw(sha256_hex);
use Comserv::Util::Logging;
use Comserv::Util::AccessCheck;

BEGIN { extends 'Catalyst::Controller'; }

=head1 NAME

Comserv::Controller::Admin::RolePermissions - admin page for role_permissions rows

=head1 DESCRIPTION

/admin/role_permissions lists, adds, edits and deletes the data rows that
Comserv::Util::AccessCheck reads ("role R may do ACTION on MODULE on SITENAME,
optionally own records only"). Admin session only. Every change is POST plus a
session CSRF token (same pattern as Admin::CloudflareCache).

=cut

has 'logging' => (is => 'ro', default => sub { Comserv::Util::Logging->instance });

sub _log { my ($self, $c, $lvl, $sub, $msg) = @_; eval { $self->logging->log_with_details($c, $lvl, __FILE__, __LINE__, $sub, $msg); 1 } }

# Global admin only, decided from the STORED users.roles field. Session roles are
# not used: login merges site roles into them, and a site admin must not edit the
# permission rows that apply to every site.
sub _is_admin {
    my ($self, $c) = @_;
    my $uid = $c->session->{user_id};
    return 0 unless defined $uid && $uid =~ /^\d+$/;
    return Comserv::Util::AccessCheck->is_global_admin($c->model('DBEncy'), $uid);
}

sub begin :Private {
    my ($self, $c) = @_;
    return 1 if $self->_is_admin($c);
    $self->_log($c, 'warn', 'begin', 'role_permissions: non-admin access denied');
    $c->res->redirect($c->uri_for('/user/login', { return_to => '/admin/role_permissions' }));
    $c->detach;
}

sub _csrf_token {
    my ($self, $c) = @_;
    my $t = $c->session->{roleperm_csrf};
    unless ($t) {
        my $rand = '';
        if (open(my $fh, '<:raw', '/dev/urandom')) { read($fh, $rand, 32); close $fh }
        $t = sha256_hex($rand . time . $$ . rand());
        $c->session->{roleperm_csrf} = $t;
    }
    return $t;
}

sub _csrf_ok {
    my ($self, $c) = @_;
    return 0 unless uc($c->req->method // '') eq 'POST';
    my $want = $c->session->{roleperm_csrf};
    my $got  = $c->req->params->{csrf};
    return 0 unless defined $want && length $want && defined $got && !ref $got && length($got) == length($want);
    my $diff = 0;
    $diff |= ord(substr($want, $_, 1)) ^ ord(substr($got, $_, 1)) for 0 .. length($want) - 1;
    return $diff == 0 ? 1 : 0;
}

sub _rs { my ($self, $c) = @_; return eval { $c->model('DBEncy')->resultset('RolePermission') } }

# Validate form fields. Returns (\%row, undef) or (undef, $error).
sub _validate {
    my ($self, $p) = @_;
    my %r;
    for my $k (qw(role module action sitename)) {
        my $v = $p->{$k};
        $v = '' if !defined $v || ref $v;
        $v =~ s/^\s+|\s+$//g;
        $r{$k} = $v;
    }
    $r{role}   = lc $r{role};
    $r{module} = lc $r{module};
    $r{action} = lc $r{action};
    return (undef, 'Role must be 1-50 letters, digits, _ . or -') unless $r{role} =~ /^[a-z0-9_.\-]{1,50}$/;
    return (undef, "'$r{role}' cannot hold rights: guest and user are not accounts")
        if grep { $_ eq $r{role} } @Comserv::Util::AccessCheck::NO_ACCOUNT_ROLES;
    return (undef, "'$r{role}' is not a role in the role system")
        if grep { $_ eq $r{role} } @Comserv::Util::AccessCheck::NOT_ROLES;
    return (undef, 'Module must be 1-100 letters, digits, _ . or -') unless $r{module} =~ /^[a-z0-9_.\-]{1,100}$/;
    return (undef, 'Action must be read, create, update or delete') unless Comserv::Util::AccessCheck->valid_action($r{action});
    if ($r{sitename} eq '' || $r{sitename} eq '*') { $r{sitename} = undef }
    elsif ($r{sitename} !~ /^[A-Za-z0-9_.\-]{1,100}$/) { return (undef, 'Site name has invalid characters') }
    $r{own_only} = $p->{own_only} && !ref $p->{own_only} ? 1 : 0;
    my $g = $p->{requires_grant};
    $g = '' if !defined $g || ref $g;
    $g =~ s/^\s+|\s+$//g;
    return (undef, 'Requires-grant module must be letters, digits, _ . or -') if length $g && $g !~ /^[A-Za-z0-9_.\-]{1,100}$/;
    $r{requires_grant} = length $g ? lc $g : undef;
    return (\%r, undef);
}

sub index :Path('/admin/role_permissions') :Args(0) {
    my ($self, $c) = @_;
    my $rs = $self->_rs($c);
    my @rows = $rs ? eval { $rs->search({}, { order_by => [qw(role module action sitename)] })->all } : ();
    my $table_ok = ($rs && !$@) ? 1 : 0;
    my @sitenames = eval { $c->model('DBEncy')->resultset('Site')->search({}, { columns => ['name'], order_by => 'name' })->get_column('name')->all };
    $c->stash(
        perms      => \@rows,
        table_ok   => $table_ok,
        rbac_on    => (Comserv::Util::AccessCheck->rbac_active($c->model('DBEncy')) ? 1 : 0),
        sitenames  => \@sitenames,
        actions    => [ @Comserv::Util::AccessCheck::ACTIONS ],
        real_roles => [ @Comserv::Util::AccessCheck::REAL_ROLES ],
        edit_id    => scalar($c->req->params->{edit}),
        starter    => [ Comserv::Util::AccessCheck->starter_rows ],
        rp_csrf    => $self->_csrf_token($c),
        template   => 'admin/role_permissions.tt',
    );
}

sub save :Path('/admin/role_permissions/save') :Args(0) {
    my ($self, $c) = @_;
    my $back = $c->uri_for('/admin/role_permissions');
    unless ($self->_csrf_ok($c)) {
        $c->flash->{error_msg} = 'Form expired or invalid. Please try again.';
        $c->res->redirect($back); return $c->detach;
    }
    my $p = $c->req->params;
    my ($row, $err) = $self->_validate($p);
    my $rs = $self->_rs($c);
    $err ||= 'role_permissions table not available yet: create it in Schema Compare first' unless $rs;
    my $id = $p->{id};
    $id = undef unless defined $id && !ref $id && $id =~ /^\d+$/;
    # The first row switches every non-admin from the old role list to data rules,
    # so it needs an explicit confirmation (or use "Add starter rows").
    if (!$err && !$id && !Comserv::Util::AccessCheck->rbac_active($c->model('DBEncy')) && !$p->{confirm_first}) {
        $err = 'This would be the FIRST permission row: it switches every non-admin user and bot from the old '
             . 'role list to these rows, so roles without rows (e.g. editor) would lose access. Add the starter rows first, '
             . 'or tick "I understand" to save this row on its own.';
    }
    unless ($err) {
        my $dup = eval { $rs->search({ role => $row->{role}, module => $row->{module}, action => $row->{action},
            sitename => $row->{sitename}, ($id ? (id => { '!=' => $id }) : ()) }, { rows => 1 })->count };
        $err = 'That role/module/action/site row already exists' if $dup;
    }
    unless ($err) {
        my $ok = eval {
            if ($id) {
                my $r = $rs->find($id) or die "not found\n";
                $r->update($row);
            } else {
                $rs->create({ %$row, created_by => ($c->session->{username} // '') });
            }
            1;
        };
        $err = 'Save failed' unless $ok;
        $self->_log($c, $ok ? 'info' : 'error', 'save', sprintf('role_permissions %s id=%s role=%s module=%s action=%s site=%s own_only=%d by %s%s',
            ($id ? 'update' : 'create'), ($id // 'new'), $row->{role}, $row->{module}, $row->{action},
            ($row->{sitename} // '*') . ' grant=' . ($row->{requires_grant} // '-'), $row->{own_only}, ($c->session->{username} // '?'), ($ok ? '' : ': ' . substr("$@", 0, 200))));
    }
    if ($err) { $c->flash->{error_msg} = $err } else { $c->flash->{status_msg} = 'Saved.' }
    $c->res->redirect($back);
    $c->detach;
}

sub starter :Path('/admin/role_permissions/starter') :Args(0) {
    my ($self, $c) = @_;
    my $back = $c->uri_for('/admin/role_permissions');
    unless ($self->_csrf_ok($c)) {
        $c->flash->{error_msg} = 'Form expired or invalid. Please try again.';
        $c->res->redirect($back); return $c->detach;
    }
    my $rs = $self->_rs($c);
    my ($added, $had) = (0, 0);
    my $ok = $rs && eval {
        $c->model('DBEncy')->schema->txn_do(sub {
            for my $r (Comserv::Util::AccessCheck->starter_rows) {
                my $n = $rs->search({ role => $r->{role}, module => $r->{module}, action => $r->{action}, sitename => undef })->count;
                if ($n) { $had++; next }
                $rs->create({ %$r, created_by => ($c->session->{username} // '') });
                $added++;
            }
        });
        1;
    };
    $self->_log($c, $ok ? 'info' : 'error', 'starter',
        "role_permissions starter rows: added=$added existing=$had by " . ($c->session->{username} // '?') . ($ok ? '' : ': ' . substr("$@", 0, 200)));
    if ($ok) { $c->flash->{status_msg} = "Starter rows added: $added (already there: $had)." }
    else     { $c->flash->{error_msg} = $rs ? 'Adding starter rows failed; nothing was changed.' : 'role_permissions table not available yet: create it in Schema Compare first' }
    $c->res->redirect($back);
    $c->detach;
}

sub remove_row :Path('/admin/role_permissions/delete') :Args(0) {
    my ($self, $c) = @_;
    my $back = $c->uri_for('/admin/role_permissions');
    unless ($self->_csrf_ok($c)) {
        $c->flash->{error_msg} = 'Form expired or invalid. Please try again.';
        $c->res->redirect($back); return $c->detach;
    }
    my $id = $c->req->params->{id};
    my $rs = $self->_rs($c);
    if ($rs && defined $id && !ref $id && $id =~ /^\d+$/ && (my $r = eval { $rs->find($id) })) {
        my $desc = join('/', map { $r->get_column($_) // '*' } qw(role module action sitename));
        if (eval { $r->delete; 1 }) {
            $self->_log($c, 'info', 'delete', "role_permissions id=$id ($desc) deleted by " . ($c->session->{username} // '?'));
            $c->flash->{status_msg} = 'Deleted.';
        } else { $c->flash->{error_msg} = 'Delete failed' }
    } else { $c->flash->{error_msg} = 'Row not found' }
    $c->res->redirect($back);
    $c->detach;
}

__PACKAGE__->meta->make_immutable;
1;
