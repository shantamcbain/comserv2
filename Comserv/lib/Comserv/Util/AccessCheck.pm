package Comserv::Util::AccessCheck;
use strict;
use warnings;
use DateTime;

=head1 NAME

Comserv::Util::AccessCheck - one data-driven permission check for users and bots

=head1 SYNOPSIS

  my $r = Comserv::Util::AccessCheck->check($schema,
      user     => { user_id => 12, username => 'shanta_secretary', roles => ['user'] },
      module   => 'todo',          # todo | calendar | project | ...
      action   => 'update',        # read | create | update | delete
      sitename => 'Shanta',
      record   => $todo_row,       # optional; needed for own_only
      token    => $api_token_row,  # optional; scope_* columns narrow the user's rights
  );
  # { ok => 1, mode => 'admin'|'rbac'|'legacy', role => 'secretary' }
  # { ok => 0, status => 403, code => 'forbidden', error => '...' }

=head1 RULES (in order)

=over

=item 1. Token scope (when a token is given). C<scope_sites>, C<scope_modules>,
C<scope_actions> are comma-separated lists (case-insensitive, C<*> = any).
NULL/empty = inherit the user's rights. A set scope can only narrow: the token
is refused for anything outside it, and the user's own rights below still apply,
so a token never exceeds its user. Token C<own_only>=1 forces the ownership rule.

=item 2. Global admin or developer (users.roles / session roles) passes.

=item 3. user_module_access: a row for (username, sitename, module) with
granted=0 refuses (the module off switch).

=item 4. Mode. If the role_permissions table is missing or has no rows the
check is in C<legacy> mode: the old role list (default admin developer devops
editor) decides, with no site check, so nothing changes until Shanta enters the
first permission rows. Once any row exists the check is in C<rbac> mode.

=item 5. rbac: the user needs an active, unexpired user_site_roles row for the
site (site_id = sites.id of the sitename, or site_id NULL = all sites), AND a
role_permissions row for one of those roles with this module and action whose
sitename equals the site or is NULL. If every matching row has own_only=1 the
record must belong to the user (see L</owns>).

=back

=head1 GLOBAL vs SITE ROLES

Admin/developer pass uses the stored users.roles field, never the session (login
merges site roles into the session). A user_site_roles admin passes only on that
site. In rbac mode the roles that count on a site are its user_site_roles rows
plus the user's global users.roles.

=head1 OWNERSHIP (owns)

todo / calendar: record.user_id == caller id, or owner, username_of_poster or
developer equals the caller's username (case-insensitive).
project: username_of_poster or developer_name equals the username.
any other module: user_id, owner or username_of_poster.
A create (no record yet) always counts as owned: the API forces the poster to
the authenticated caller.

=cut

our @ACTIONS        = qw(read create update delete);
our @LEGACY_ROLES   = qw(admin developer devops editor);
our @PASS_ROLES     = qw(admin developer);
# Shanta's role set (Oct 31 2026), the same standard set on every SiteName.
our @REAL_ROLES     = qw(normal member editor developer helpdesk admin);
# guest = not logged in, user = no account: they can never hold rights here.
our @NO_ACCOUNT_ROLES = qw(guest user anonymous);
# Not a role in the role system (still used by pre-existing bot-token code).
our @NOT_ROLES      = qw(devops);
# The default site: user_site_roles rows on it grant nothing.
our $NO_RIGHTS_SITE = 'none';

sub norm_site { my ($class, $s) = @_; $s = '' unless defined $s; $s =~ s/^\s+|\s+$//g; return $s }
sub is_no_rights_site { my ($class, $s) = @_; return lc($class->norm_site($s)) eq $NO_RIGHTS_SITE ? 1 : 0 }
our $MAX_LIST_LEN   = 500;

sub valid_action { my ($class, $a) = @_; return (defined $a && grep { $_ eq lc $a } @ACTIONS) ? 1 : 0 }

sub roles_list {
    my ($class, $raw) = @_;
    my @r = ref($raw) eq 'ARRAY' ? @$raw : (defined $raw && !ref($raw) ? split(/[\s,;|]+/, $raw) : ());
    return [ grep { length } map { lc } grep { defined && !ref } @r ];
}

# Comma list -> arrayref (lowercased, trimmed); undef/empty -> undef (inherit).
sub parse_scope {
    my ($class, $v) = @_;
    return undef unless defined $v && !ref($v) && $v =~ /\S/;
    my @l = grep { length } map { my $x = lc $_; $x =~ s/^\s+|\s+$//g; $x } split /,/, $v;
    return @l ? \@l : undef;
}

# Validate + normalise a scope list supplied by an admin. Returns (value, error).
sub normalise_scope {
    my ($class, $v, $kind) = @_;
    return (undef, undef) unless defined $v && (ref($v) eq 'ARRAY' ? @$v : (!ref($v) && $v =~ /\S/));
    my @l = ref($v) eq 'ARRAY' ? @$v : split /,/, $v;
    my @out;
    for my $x (@l) {
        return (undef, "$kind must be a comma list of names") if ref $x || !defined $x;
        $x =~ s/^\s+|\s+$//g;
        next unless length $x;
        return (undef, "$kind entry '$x' is not allowed") unless $x =~ /^(?:\*|[A-Za-z0-9_.\-]{1,100})$/;
        $x = lc $x unless $kind eq 'scope_sites';
        return (undef, "scope_actions entry '$x' must be read, create, update or delete")
            if $kind eq 'scope_actions' && $x ne '*' && !$class->valid_action($x);
        push @out, $x;
    }
    return (undef, undef) unless @out;
    my $s = join(',', @out);
    return (undef, "$kind is too long") if length($s) > $MAX_LIST_LEN;
    return ($s, undef);
}

sub _col { my ($obj, $col) = @_; return undef unless $obj;
    return $obj->{$col} if ref($obj) eq 'HASH';
    return undef unless eval { $obj->can('has_column') ? $obj->has_column($col) : $obj->can($col) };
    my $v = eval { $obj->get_column($col) }; return $v }

sub _in { my ($list, $v) = @_; return 1 unless $list; $v = lc($v // '');
    return scalar grep { $_ eq '*' || $_ eq $v } @$list }

sub owns {
    my ($class, $module, $record, $user) = @_;
    return 1 unless $record;
    my $uid = $user->{user_id}; my $un = lc($user->{username} // '');
    my $eq = sub { my $v = _col($record, $_[0]); defined $v && length $un && lc($v) eq $un };
    $module = lc($module // '');
    if ($module eq 'todo' || $module eq 'calendar') {
        my $ru = _col($record, 'user_id');
        return 1 if defined $ru && defined $uid && $ru =~ /^\d+$/ && $uid =~ /^\d+$/ && $ru == $uid;
        return ($eq->('owner') || $eq->('username_of_poster') || $eq->('developer')) ? 1 : 0;
    }
    if ($module eq 'project') {
        return ($eq->('username_of_poster') || $eq->('developer_name')) ? 1 : 0;
    }
    my $ru = _col($record, 'user_id');
    return 1 if defined $ru && defined $uid && "$ru" eq "$uid";
    return ($eq->('owner') || $eq->('username_of_poster')) ? 1 : 0;
}

sub _rs { my ($schema, $name) = @_; my $rs = eval { $schema->resultset($name) }; return $rs }

# 1 = rbac data present, 0 = legacy (table/source missing or empty).
sub rbac_active {
    my ($class, $schema) = @_;
    my $rs = _rs($schema, 'RolePermission') or return 0;
    my $n = eval { $rs->search({}, { rows => 1 })->count };
    return ($n && !$@) ? 1 : 0;
}

# Site names are matched trimmed and case-insensitively (a stored 'SB ' still
# matches 'SB'). The 'none' default site never resolves.
sub _site_id {
    my ($schema, $sitename) = @_;
    my $want = Comserv::Util::AccessCheck->norm_site($sitename);
    return undef if $want eq '' || Comserv::Util::AccessCheck->is_no_rights_site($want);
    my $rs = _rs($schema, 'Site') or return undef;
    my @s = eval { $rs->search({ -or => [ { name => $want }, \[ 'LOWER(TRIM(name)) = ?', lc $want ] ] }, { rows => 2 })->all };
    # More than one site after trim/case-fold (e.g. 'SB' and 'SB '): ambiguous,
    # resolve to none (no site rights); check() refuses with site_ambiguous.
    return undef if @s != 1;
    return $s[0]->id;
}

sub site_ambiguous {
    my ($class, $schema, $sitename) = @_;
    my $want = $class->norm_site($sitename);
    return 0 if $want eq '';
    my $rs = _rs($schema, 'Site') or return 0;
    my $n = eval { $rs->search({ -or => [ { name => $want }, \[ 'LOWER(TRIM(name)) = ?', lc $want ] ] }, { rows => 2 })->count };
    return ($n && $n > 1) ? 1 : 0;
}

# ids of sites named 'none' (any case/spaces): their user_site_roles grant nothing.
sub _no_rights_site_ids {
    my ($schema) = @_;
    my $rs = _rs($schema, 'Site') or return ();
    return eval { map { $_->id } $rs->search(\[ 'LOWER(TRIM(name)) = ?', $NO_RIGHTS_SITE ])->all };
}

# Has the user subscribed to / been granted a module on this site? Today's
# mechanisms (same ones Root.pm uses for enabled_modules), per user only:
#   user_module_access  (username, sitename, module_name, granted=1)
#   membership_service_access (user_id, site_id, service_name, is_active=1, not expired)
# Site-wide site_modules switches are NOT a personal subscription.
sub has_module_grant {
    my ($class, $schema, $user, $sitename, $module) = @_;
    my $site = $class->norm_site($sitename);
    return 0 if $site eq '' || $class->is_no_rights_site($site);
    my $mod = lc($module // '');
    if (my $uma = _rs($schema, 'UserModuleAccess')) {
        my $n = eval { $uma->search({ username => $user->{username} // '', granted => 1,
            -and => [ \[ 'LOWER(TRIM(sitename)) = ?', lc $site ], \[ 'LOWER(TRIM(module_name)) = ?', $mod ] ] }, { rows => 1 })->count };
        return 1 if $n;
    }
    if (defined $user->{user_id} && $user->{user_id} =~ /^\d+$/ and my $msa = _rs($schema, 'MembershipServiceAccess')) {
        my $sid = _site_id($schema, $site);
        if (defined $sid) {
            my @g = eval { $msa->search({ user_id => $user->{user_id}, site_id => $sid, is_active => 1,
                -and => [ \[ 'LOWER(TRIM(service_name)) = ?', $mod ] ] })->all };
            # An is_expired error counts as expired (fail closed).
            return 1 if grep { my $x = eval { $_->is_expired }; !$@ && !$x } @g;
        }
    }
    return 0;
}

# Active user_site_roles for the user on this site (site_id match or NULL).
sub site_roles {
    my ($class, $schema, $user_id, $sitename) = @_;
    return [] unless defined $user_id && $user_id =~ /^\d+$/;
    my $rs = _rs($schema, 'UserSiteRole') or return [];
    my $sid = defined $sitename && length $sitename ? _site_id($schema, $sitename) : undef;
    return [] if $class->is_no_rights_site($sitename);
    my %none = map { $_ => 1 } _no_rights_site_ids($schema);
    my @rows = grep { !(defined $_->site_id && $none{ $_->site_id }) } eval { $rs->search({
        user_id   => $user_id,
        is_active => 1,
        site_id   => [ undef, (defined $sid ? $sid : ()) ],
    })->all };
    # Expiry uses the app clock (Comserv::Util::AppTime: stored naive times are UTC).
    require Comserv::Util::AppTime;
    my $now = Comserv::Util::AppTime->now_dt;
    my %seen;
    return [ grep { !$seen{$_}++ } map { lc $_->role } grep {
        my $e = eval { $_->get_column('expires_at') };
        my $edt = (defined $e && "$e" ne '') ? Comserv::Util::AppTime->parse_stored("$e") : undef;
        !defined $e || "$e" eq '' || ($edt && DateTime->compare($edt, $now) >= 0)
    } @rows ];
}

# Roles from the STORED users.roles field (not the session, which merges site roles
# at login). undef when the users table is not reachable.
sub stored_roles {
    my ($class, $schema, $user_id) = @_;
    return undef unless defined $user_id && $user_id =~ /^\d+$/;
    my $rs = _rs($schema, 'User') or return undef;
    my $u = eval { $rs->find($user_id) };
    return undef if $@;
    return [] unless $u;
    return $class->roles_list(eval { $u->get_column('roles') });
}

# Is this user a global admin by the stored users.roles field?
sub is_global_admin {
    my ($class, $schema, $user_id) = @_;
    my $r = $class->stored_roles($schema, $user_id) or return 0;
    return (grep { $_ eq 'admin' } @$r) ? 1 : 0;
}

# DBIC condition selecting the records a user owns (same rule as owns()).
sub own_where {
    my ($class, $module, $user) = @_;
    my $uid = $user->{user_id}; my $un = $user->{username} // '';
    $module = lc($module // '');
    my @or;
    push @or, { user_id => $uid } if defined $uid && $uid =~ /^\d+$/ && $module ne 'project';
    if (length $un) {
        if ($module eq 'project') { push @or, { username_of_poster => $un }, { developer_name => $un } }
        elsif ($module eq 'todo' || $module eq 'calendar') { push @or, map { { $_ => $un } } qw(owner username_of_poster developer) }
        else { push @or, { owner => $un }, { username_of_poster => $un } }
    }
    return @or ? { -or => \@or } : { user_id => -1 };
}

# Starter rows reproducing today's legacy role lists (see LEGACY ACCESS below).
# Admin and developer always pass, so they need no rows.
#   API todo/project writes + work log + rank: admin developer devops editor
#   web /todo pages: admin developer;  web delete: admin developer editor
#   web quick_close / open_log / close_log: admin developer editor devops
# todo/read is needed for the API work_status and rank dry runs (old list had
# devops/editor); it also opens the web /todo pages to editor/devops, which the old
# web check (admin/developer) did not.
# done_with_log on the web also allowed plain user/normal; that is NOT seeded
# because a 'user' row would also open the API to every plain account.
#
# Shanta's rules (Oct 31 2026) replace the devops rows: devops is not a role.
#   editor    : today's legacy access (todo read/create/update/delete, project read/create/update)
#   helpdesk  : no todo/project access in any legacy list -> no rows (HelpDesk tickets
#               are not gated by AccessCheck)
#   normal, member : todo + calendar read/create/update on their OWN records, and only
#               when subscribed to planning (requires_grant = 'planning')
#   admin, developer : no rows, they always pass
#   guest, user : no rows, no accounts, no planning/todo/calendar rights
# [role, module, action, own_only, requires_grant]
our @STARTER_ROWS = (
    (map { ['editor', 'todo', $_, 0, undef] } qw(read create update delete)),
    (map { ['editor', 'project', $_, 0, undef] } qw(read create update)),
    (map { my $r = $_; map { my $m = $_; map { [$r, $m, $_, 1, 'planning'] } qw(read create update) } qw(todo calendar) } qw(normal member)),
);
sub starter_rows { return map { { role => $_->[0], module => $_->[1], action => $_->[2], own_only => $_->[3],
    requires_grant => $_->[4], sitename => undef } } @STARTER_ROWS }

# Scope columns of a token, read with an explicit column list so a database that
# does not have them yet (before Schema Compare) only logs a WARN and the token is
# treated as unscoped (it cannot have a scope then anyway).
sub token_scope {
    my ($class, $schema, $token_id, $warn) = @_;
    return undef unless defined $token_id;
    my $rs = _rs($schema, 'ApiToken') or return undef;
    my $row = eval { $rs->search({ 'me.id' => $token_id },
        { columns => [qw(id scope_sites scope_modules scope_actions own_only)] })->single };
    if (my $e = $@) {
        # Only "column does not exist yet" (before Schema Compare) falls back to
        # unscoped. Any other DB error fails CLOSED: check() refuses the token.
        if ("$e" =~ /unknown column|no such column|has no column named/i) {
            $warn->("api_tokens scope columns not present yet (apply Schema Compare); token treated as unscoped") if $warn;
            return undef;
        }
        $warn->("api_tokens scope read failed; token refused (fail closed)") if $warn;
        return { _scope_error => 1 };
    }
    return undef unless $row;
    return { map { $_ => scalar(eval { $row->get_column($_) }) } qw(scope_sites scope_modules scope_actions own_only) };
}

sub _deny { my ($error, $code) = @_; return { ok => 0, status => 403, code => $code || 'forbidden', error => $error } }

sub check {
    my ($class, $schema, %a) = @_;
    my $user   = $a{user} || {};
    my $module = lc($a{module} // '');
    my $action = lc($a{action} // '');
    my $site   = $a{sitename} // '';
    my $roles  = $class->roles_list($user->{roles});
    return _deny('Unknown action') unless $class->valid_action($action);
    return _deny('Unknown module') unless $module =~ /^[a-z0-9_.\-]{1,100}$/;

    my $own_forced = 0;
    if (my $t = $a{token}) {
        return _deny('Token scope could not be read; try again later', 'token_scope_error') if _col($t, '_scope_error');
        my $ss = $class->parse_scope(_col($t, 'scope_sites'));
        my $sm = $class->parse_scope(_col($t, 'scope_modules'));
        my $sa = $class->parse_scope(_col($t, 'scope_actions'));
        return _deny("Token scope does not include site '$site'", 'token_scope') unless _in($ss, $site);
        return _deny("Token scope does not include module '$module'", 'token_scope') unless _in($sm, $module);
        return _deny("Token scope does not include action '$action'", 'token_scope') unless _in($sa, $action);
        $own_forced = _col($t, 'own_only') ? 1 : 0;
    }
    my $own_ok = sub { $action eq 'create' || $class->owns($module, $a{record}, $user) };

    # Admin/developer pass is decided from the STORED users.roles (session roles
    # include site roles merged at login). Falls back to the given roles only when
    # the users table cannot be read.
    my $stored = $class->stored_roles($schema, $user->{user_id});
    my $global = $stored || $roles;
    if (grep { my $r = $_; grep { $_ eq $r } @PASS_ROLES } @$global) {
        return _deny('Token is limited to its own records', 'own_only') if $own_forced && !$own_ok->();
        return { ok => 1, mode => 'admin', role => (grep { $_ eq 'admin' } @$global) ? 'admin' : 'developer' };
    }
    # A site admin (user_site_roles role=admin for THIS site) passes on that site only.
    my $site_roles = $class->site_roles($schema, $user->{user_id}, $site);
    if (grep { $_ eq 'admin' } @$site_roles) {
        return _deny('Token is limited to its own records', 'own_only') if $own_forced && !$own_ok->();
        return { ok => 1, mode => 'site_admin', role => 'admin' };
    }

    if (my $uma = _rs($schema, 'UserModuleAccess')) {
        my $off = eval { $uma->search({ username => $user->{username} // '', sitename => $site,
                                        module_name => $module, granted => 0 }, { rows => 1 })->count };
        return _deny("Module '$module' is switched off for this user on $site", 'module_off') if $off;
    }

    unless ($class->rbac_active($schema)) {
        my %ok = map { $_ => 1 } @{ $a{legacy_roles} || \@LEGACY_ROLES };
        # admin/developer were already decided from users.roles above; a session
        # 'admin' merged from another site's role must not pass here.
        if ($stored) { delete $ok{$_} for @PASS_ROLES }
        # legacy_roles => ['*']: the old check was "any logged-in user".
        if ($ok{'*'} && defined $user->{user_id} && length $user->{user_id}) {
            return _deny('Token is limited to its own records', 'own_only') if $own_forced && !$own_ok->();
            return { ok => 1, mode => 'legacy', role => ($roles->[0] // 'user') };
        }
        my ($r) = grep { $ok{$_} } @$roles;
        return _deny('Your account has no role permitted for this action') unless $r;
        return _deny('Token is limited to its own records', 'own_only') if $own_forced && !$own_ok->();
        return { ok => 1, mode => 'legacy', role => $r };
    }

    # Roles that count on this site: its user_site_roles rows plus the user's global
    # users.roles (a global role is a role on every site).
    # guest/user/anonymous never count; the 'none' default site grants nothing.
    return _deny("Site '$site' grants no rights", 'no_rights_site') if $class->is_no_rights_site($site);
    return _deny("Site name '$site' matches more than one site; ask an admin to fix the site names", 'site_ambiguous')
        if $class->site_ambiguous($schema, $site);
    my %noacc = map { $_ => 1 } @NO_ACCOUNT_ROLES;
    my %rs = map { $_ => 1 } grep { !$noacc{$_} } @$site_roles, @{ $stored || [] };
    my $sr = [ sort keys %rs ];
    return _deny("You have no role on site '$site'", 'no_site_role') unless @$sr;
    my $nsite = $class->norm_site($site);
    my @perm = eval { _rs($schema, 'RolePermission')->search({
        role => { -in => $sr }, module => $module, action => $action,
        -or => [ { sitename => undef }, \[ 'LOWER(TRIM(sitename)) = ?', lc $nsite ] ],
    })->all };
    # Rows for roles that cannot hold rights (devops, guest, user, anonymous) are ignored.
    my %badrole = map { $_ => 1 } @NO_ACCOUNT_ROLES, @NOT_ROLES;
    @perm = grep { !$badrole{ lc($_->role // '') } } @perm;
    # Rows with requires_grant apply only when the user holds that module grant
    # (e.g. normal/member + planning subscription).
    my %grant;
    @perm = grep {
        my $g = eval { $_->get_column('requires_grant') };
        !(defined $g && length $g) || ($grant{lc $g} //= $class->has_module_grant($schema, $user, $site, $g))
    } @perm;
    return _deny("Your role on '$site' does not allow $action on $module (subscribe to the module if your role needs it)", 'no_permission') unless @perm;
    my @free = grep { !$_->own_only } @perm;
    my $need_own = (!@free || $own_forced) ? 1 : 0;
    return _deny("You may only $action your own $module records", 'own_only') if $need_own && !$own_ok->();
    my $role = lc(($free[0] || $perm[0])->role);
    return { ok => 1, mode => 'rbac', role => $role, own_only => $need_own };
}

# Role to record in group_of_poster: admin/developer, else first site role, else first global role.
sub poster_group {
    my ($class, $schema, $user, $sitename) = @_;
    my $roles = $class->roles_list($user->{roles});
    for my $p (@PASS_ROLES) { return $p if grep { $_ eq $p } @$roles }
    my $sr = $class->site_roles($schema, $user->{user_id}, $sitename);
    return substr($sr->[0], 0, 50) if @$sr;
    return substr($roles->[0], 0, 50) if @$roles;
    return 'user';
}

# Web helper: session identity -> check(). Returns the same hash.
sub check_session {
    my ($class, $c, %a) = @_;
    my $s = $c->session || {};
    my $schema = $c->model('DBEncy');
    # Session roles are used only for legacy mode; admin is decided from users.roles.
    my $roles = $class->roles_list($c->stash->{user_roles} || $s->{roles});
    my $site = $a{sitename} // $c->stash->{SiteName} // $s->{SiteName} // 'CSC';
    return $class->check($schema, %a, sitename => $site,
        user => { user_id => $s->{user_id}, username => $s->{username}, roles => $roles });
}

1;
