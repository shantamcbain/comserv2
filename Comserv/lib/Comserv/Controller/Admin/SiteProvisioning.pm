package Comserv::Controller::Admin::SiteProvisioning;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use Comserv::Util::AdminAuth;
use Comserv::Util::CloudflareManager;
use Try::Tiny;
use File::Path qw(make_path);
use POSIX qw(strftime);
use JSON qw(decode_json encode_json);
use File::Spec;
use URI::Escape;

BEGIN { extends 'Catalyst::Controller'; }

__PACKAGE__->config(namespace => 'admin/site_provisioning');

has 'logging' => (is => 'ro', default => sub { Comserv::Util::Logging->instance });
has 'admin_auth' => (is => 'ro', default => sub { Comserv::Util::AdminAuth->new });

sub auto :Private {
    my ($self, $c) = @_;
    unless ($self->admin_auth->is_csc_admin($c)) {
        $c->flash->{error_msg} = 'CSC administrator access required.';
        $c->response->redirect($c->uri_for('/'));
        return 0;
    }
    return 1;
}

sub index :Path :Args(0) {
    my ($self, $c) = @_;
    my @requests = $c->model('DBEncy')->resultset('Accounting::HostingAccount')->search(
        {},
        { order_by => { -desc => 'created_at' } }
    )->all;
    $c->stash(
        template => 'admin/site_provisioning/index.tt',
        requests => \@requests,
    );
}

sub add :Path('add') :Args(0) {
    my ($self, $c) = @_;

    if ($c->req->method eq 'POST') {
        my $p = $c->req->params;
        my @errors;
        push @errors, 'Site name is required' unless $p->{sitename};
        push @errors, 'Domain is required'    unless $p->{domain};

        if (@errors) {
            $c->stash(
                template   => 'admin/site_provisioning/add.tt',
                errors     => \@errors,
                form_data  => $p,
            );
            return;
        }

        eval {
            $c->model('DBEncy')->resultset('Accounting::HostingAccount')->create({
                sitename      => $p->{sitename},
                domain        => $p->{domain},
                domain_type   => $p->{domain_type}   || 'subdomain',
                contact_email => $p->{contact_email} || '',
                plan_slug     => $p->{plan_slug}     || 'hosting-subdomain',
                status        => $p->{status}        || 'pending',
                notes         => $p->{notes}         || '',
                created_by    => $c->session->{username} || 'admin',
            });
        };
        if ($@) {
            $c->stash(
                template  => 'admin/site_provisioning/add.tt',
                errors    => ["Failed to create record: $@"],
                form_data => $p,
            );
            return;
        }

        $c->flash->{success_msg} = "Site request for '$p->{sitename}' added.";
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }

    my ($cf_zones, $default_domain, $server_ip, $cf_error) = $self->_get_cloudflare_data($c);
    $c->stash(
        template       => 'admin/site_provisioning/add.tt',
        cf_zones       => $cf_zones,
        default_domain => $default_domain,
        server_ip      => $server_ip,
        cf_error       => $cf_error,
    );
}

sub _get_cloudflare_data {
    my ($self, $c) = @_;
    my @zones;
    my $default_domain = '';
    my $server_ip = $ENV{SERVER_PUBLIC_IP} || '';

    my $site_name = $c->session->{SiteName} || $c->stash->{SiteName} || '';
    if ($site_name) {
        my $sd = eval {
            $c->model('DBEncy')->resultset('SiteDomain')
              ->search({ site_id => { -in =>
                  $c->model('DBEncy')->resultset('Site')
                    ->search({ name => $site_name }, { columns => ['id'] })
                    ->as_query
              }}, { rows => 1 })->first
        };
        $default_domain = $sd->domain if $sd;
    }

    my $cf_error = '';
    eval {
        my $dbh = eval { $c->model('DBEncy')->storage->dbh };
        my $cf = Comserv::Util::CloudflareManager->new(dbh => $dbh);
        my $cf_email = $cf->config->{cloudflare}{email} || '';
        my $token    = $cf->config->{cloudflare}{api_token} || '';

        unless ($token) {
            die "No Cloudflare API token found. Please set it at Cloudflare Credentials.";
        }

        my $raw = $cf->_api_request('GET', '/zones?per_page=50');
        my @raw_zones = ref $raw eq 'HASH'  ? @{ $raw->{result} || [] }
                      : ref $raw eq 'ARRAY' ? @$raw
                      : ();

        for my $zone (@raw_zones) {
            my $zname = ref $zone eq 'HASH' ? $zone->{name} : "$zone";
            next unless $zname;

            my @a_records;
            eval {
                my $records = $cf->_api_request('GET', "/zones/$zone->{id}/dns_records?type=A&per_page=100");
                my @recs = ref $records eq 'HASH'  ? @{ $records->{result} || [] }
                         : ref $records eq 'ARRAY' ? @$records
                         : ();
                for my $r (@recs) {
                    next unless ref $r eq 'HASH';
                    push @a_records, { name => $r->{name}, ip => $r->{content} };
                }
            };

            my $zone_ip = '';
            for my $r (@a_records) {
                if ($r->{name} eq $zname || $r->{name} eq '@') {
                    $zone_ip = $r->{ip};
                    last;
                }
            }
            $server_ip ||= $zone_ip;

            push @zones, {
                name      => $zname,
                id        => ref $zone eq 'HASH' ? ($zone->{id} || '') : '',
                ip        => $zone_ip,
                a_records => \@a_records,
            };
        }
    };
    $cf_error = $@ if $@;

    return (\@zones, $default_domain, $server_ip, $cf_error);
}

sub _get_zone_a_records {
    my ($self, $zone_name, $dbh) = @_;
    my (@a_records, $zone_ip, $error);
    eval {
        my $cf = Comserv::Util::CloudflareManager->new(dbh => $dbh);
        my $zones_resp = $cf->_api_request('GET', "/zones?name=" . URI::Escape::uri_escape($zone_name) . "&per_page=5");
        my @zones = ref $zones_resp eq 'HASH'  ? @{ $zones_resp->{result} || [] }
                  : ref $zones_resp eq 'ARRAY' ? @$zones_resp
                  : ();
        my $zone_id = @zones ? $zones[0]{id} : '';
        die "Zone '$zone_name' not found in Cloudflare" unless $zone_id;

        my $records_resp = $cf->_api_request('GET', "/zones/$zone_id/dns_records?type=A&per_page=100");
        my @recs = ref $records_resp eq 'HASH' ? @{ $records_resp->{result} || [] } : ();
        for my $r (@recs) {
            next unless ref $r eq 'HASH';
            push @a_records, { name => $r->{name}, ip => $r->{content} };
            if (!$zone_ip && ($r->{name} eq $zone_name || $r->{name} eq '@')) {
                $zone_ip = $r->{content};
            }
        }
    };
    $error = $@ if $@;
    return (\@a_records, $zone_ip, $error);
}

sub review :Path('review') :Args(1) {
    my ($self, $c, $id) = @_;
    my $request = $c->model('DBEncy')->resultset('Accounting::HostingAccount')->find($id);
    unless ($request) {
        $c->flash->{error_msg} = "Hosting request #$id not found.";
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }

    my $domain = $request->domain || '';
    my ($zone_name) = ($domain =~ /([^.]+\.[^.]+)$/);
    $zone_name ||= $domain;

    my $dbh = eval { $c->model('DBEncy')->storage->dbh };
    my ($cf_a_records, $cf_zone_ip, $cf_error) = $self->_get_zone_a_records($zone_name, $dbh);

    my $suggested_domain = $domain;
    if ($zone_name && $domain eq $zone_name) {
        my $prefix = lc($request->sitename || '');
        $prefix =~ s/[^a-z0-9-]/-/g;
        $suggested_domain = "$prefix.$zone_name" if $prefix;
    }

    $c->stash(
        template         => 'admin/site_provisioning/review.tt',
        request          => $request,
        cf_zone_name     => $zone_name,
        cf_a_records     => $cf_a_records,
        cf_zone_ip       => $cf_zone_ip || $ENV{SERVER_PUBLIC_IP} || '',
        suggested_domain => $suggested_domain,
        cf_error         => $cf_error,
    );
}

sub provision :Path('provision') :Args(0) {
    my ($self, $c) = @_;

    return $c->response->redirect($c->uri_for($self->action_for('index')))
        unless $c->req->method eq 'POST';

    my $p = $c->req->params;
    my $id          = $p->{request_id} or do {
        $c->flash->{error_msg} = 'No request ID provided.';
        return $c->response->redirect($c->uri_for($self->action_for('index')));
    };

    my $request = $c->model('DBEncy')->resultset('Accounting::HostingAccount')->find($id);
    unless ($request) {
        $c->flash->{error_msg} = "Request #$id not found.";
        return $c->response->redirect($c->uri_for($self->action_for('index')));
    }

    my $site_name   = $p->{site_name}   || $request->sitename;
    my $domain      = $p->{domain}      || $request->domain;
    my $domain_type = $p->{domain_type} || $request->domain_type || 'subdomain';
    my $email       = $p->{email}       || $request->contact_email;
    my $display     = $p->{display_name}|| $site_name;
    my @errors;
    my @steps;

    try {
        # 1. Create site record
        my $existing_site = $c->model('DBEncy')->resultset('Site')->search({ name => $site_name })->first;
        my $site;
        if ($existing_site) {
            $site = $existing_site;
            push @steps, "Site '$site_name' already exists — skipping creation.";
        } else {
            $site = $c->model('DBEncy')->resultset('Site')->create({
                name                       => $site_name,
                description                => $display,
                site_display_name          => $display,
                affiliate                  => 1,
                pid                        => 0,
                auth_table                 => 'users',
                home_view                  => 'SiteHome',
                css_view_name              => 'default',
                mail_from                  => $email,
                mail_to                    => $email,
                mail_to_discussion         => $email,
                mail_to_admin              => $email,
                mail_to_user               => $email,
                mail_to_client             => $email,
                mail_replyto               => $email,
                app_logo                   => '/static/images/default_logo.png',
                app_logo_alt               => "$site_name Logo",
                app_logo_width             => 200,
                app_logo_height            => 100,
                document_root_url          => '/',
                link_target                => '_self',
                http_header_params         => '',
                image_root_url             => '/static/images/',
                global_datafiles_directory => '/data/',
                templates_cache_directory  => '/tmp/',
                app_datafiles_directory    => '/data/app/',
                datasource_type            => 'db',
                cal_table                  => 'calendar',
                http_header_description    => "$display website",
                http_header_keywords       => 'website',
            });
            push @steps, "Created site record for '$site_name'.";
        }

        # 2. Add sitedomain entry
        my $existing_domain = $c->model('DBEncy')->resultset('SiteDomain')->search({ domain => $domain })->first;
        unless ($existing_domain) {
            $c->model('DBEncy')->resultset('SiteDomain')->create({
                site_id => $site->id,
                domain  => $domain,
            });
            push @steps, "Mapped domain '$domain' to site '$site_name'.";
        } else {
            push @steps, "Domain '$domain' already mapped — skipping.";
        }

        # 3. Create home page template for this site
        my $root = $c->path_to('root');
        my $tpl_dir = "$root/SiteHome";
        make_path($tpl_dir) unless -d $tpl_dir;
        my $tpl_file = "$tpl_dir/${site_name}.tt";
        unless (-f $tpl_file) {
            open my $fh, '>', $tpl_file or die "Cannot write template: $!";
            print $fh _default_home_template($site_name, $display, $domain);
            close $fh;
            push @steps, "Created home page template at root/SiteHome/${site_name}.tt.";
        } else {
            push @steps, "Template already exists — skipping.";
        }

        # 4. Cloudflare DNS
        my $cf_result = $self->_create_cloudflare_dns($c, $domain, $domain_type, $p->{server_ip}, \@steps);

        # 5. Set theme
        eval { $c->model('ThemeConfig')->set_site_theme($c, $site_name, 'default') };

        # 6. Mark hosting_account active and save final domain
        $request->update({ status => 'active', domain => $domain });
        push @steps, "Hosting account marked active.";

        # 7. Grant admin role to contact_email user for this site
        my $contact_user = eval { $c->model('DBEncy')->resultset('User')->search({ email => $email })->first };
        if ($contact_user) {
            eval {
                $c->model('DBEncy')->resultset('UserSiteRole')->find_or_create({
                    user_id => $contact_user->id,
                    site_id => $site->id,
                    role    => 'admin',
                }, {
                    key => 'user_site_role_unique',
                    values => { granted_by => $c->session->{user_id} || 1, is_active => 1 },
                });
            };
            push @steps, "Granted admin role to '" . $contact_user->username . "' for site '$site_name'."
                unless $@;
        } else {
            push @steps, "No user found for '$email' — admin role not auto-assigned (user must register first).";
        }

        # 8. Create admin todo noting recompile needed
        $self->_create_admin_todo($c, $site_name, \@steps);

        $c->stash(
            template  => 'admin/site_provisioning/result.tt',
            site_name => $site_name,
            domain    => $domain,
            steps     => \@steps,
            errors    => \@errors,
            success   => 1,
        );

    } catch {
        push @errors, "Provisioning failed: $_";
        $c->stash(
            template  => 'admin/site_provisioning/result.tt',
            site_name => $site_name,
            domain    => $domain,
            steps     => \@steps,
            errors    => \@errors,
            success   => 0,
        );
    };
}

sub _create_cloudflare_dns {
    my ($self, $c, $domain, $domain_type, $server_ip, $steps) = @_;
    $server_ip ||= $ENV{SERVER_PUBLIC_IP} || '';
    unless ($server_ip) {
        push @$steps, "Cloudflare DNS: no SERVER_PUBLIC_IP configured — skipping DNS creation. Set it in .env to automate.";
        return;
    }
    try {
        my $dbh = eval { $c->model('DBEncy')->storage->dbh };
        my $cf = Comserv::Util::CloudflareManager->new(dbh => $dbh);
        my ($parent_zone, $record_name);
        if ($domain_type eq 'subdomain') {
            ($record_name, $parent_zone) = ($domain =~ /^([^.]+)\.(.+)$/);
            $parent_zone ||= $domain;
            $record_name ||= '@';
        } else {
            $parent_zone = $domain;
            $record_name = '@';
        }
        my $zones_resp = $cf->_api_request('GET', "/zones?name=" . URI::Escape::uri_escape($parent_zone) . "&per_page=5");
        my @zones = ref $zones_resp eq 'HASH'  ? @{ $zones_resp->{result} || [] }
                  : ref $zones_resp eq 'ARRAY' ? @$zones_resp
                  : ();
        my $zone_id = @zones ? $zones[0]{id} : '';
        die "Zone '$parent_zone' not found in Cloudflare" unless $zone_id;
        $cf->_api_request('POST', "/zones/$zone_id/dns_records", {
            type    => 'A',
            name    => $record_name,
            content => $server_ip,
            ttl     => 1,
            proxied => \1,
        });
        push @$steps, "Cloudflare DNS: created A record '$record_name.$parent_zone' → $server_ip.";
    } catch {
        push @$steps, "Cloudflare DNS: skipped (error: $_). Create the DNS record manually.";
    };
}

sub retry_dns :Path('retry_dns') :Args(1) {
    my ($self, $c, $id) = @_;
    $id = ref $id ? $id->[0] : $id;
    my $request = $c->model('DBEncy')->resultset('Accounting::HostingAccount')->find({ id => $id });
    unless ($request) {
        $c->flash->{error_msg} = "Request #$id not found.";
        return $c->response->redirect($c->uri_for($self->action_for('index')));
    }
    my $domain = $c->req->params->{domain} || $request->domain;
    my @steps;
    $self->_create_cloudflare_dns($c, $domain, $request->domain_type || 'subdomain',
        $c->req->params->{server_ip} || $ENV{SERVER_PUBLIC_IP} || '', \@steps);
    $c->flash->{success_msg} = join(' ', @steps);
    $c->response->redirect($c->uri_for('/admin/site_provisioning/review/' . $id));
}

sub _create_admin_todo {
    my ($self, $c, $site_name, $steps) = @_;
    my $now = strftime('%Y-%m-%d', localtime);
    eval {
        $c->model('DBEncy')->resultset('Todo')->create({
            sitename              => 'CSC',
            subject               => "[Site Provisioned] $site_name — review and restart app",
            description           => "New site '$site_name' was provisioned via the hosting signup system.\n\n"
                                   . "Steps completed:\n" . join("\n", map { "- $_" } @$steps) . "\n\n"
                                   . "ACTION REQUIRED: The app serves this site via the generic SiteHome controller. "
                                   . "No recompile is needed — routing is DB-driven.\n"
                                   . "Review the site at /site and verify DNS propagation.",
            status                => 1,
            priority              => 2,
            share                 => 0,
            project_code          => 'CSC',
            project_id            => 1,
            username_of_poster    => $c->session->{username} || 'system',
            group_of_poster       => 'admin',
            last_mod_by           => 'system',
            parent_todo           => '',
            reporter              => '',
            company_code          => 'CSC',
            owner                 => '',
            developer             => '',
            estimated_man_hours   => 0,
            user_id               => $c->session->{user_id} || 0,
            start_date            => $now,
            due_date              => $now,
            last_mod_date         => $now,
            date_time_posted      => $now,
        });
    };
}

sub _default_home_template {
    my ($site_name, $display, $domain) = @_;
    return <<"END_TT";
<div class="app-container">

<div class="page-header">
    <h1>Welcome to [% site.site_display_name || '$display' %]</h1>
</div>

<div class="content-container">
<div class="content-primary">

<div class="app-section">
    <h2>Your site is live!</h2>
    <p>This is the home page for <strong>$domain</strong>. You can now customise it through the page management system.</p>
</div>

<div class="app-section">
    <h2>Getting Started</h2>
    <ul>
        <li><strong>Add pages</strong> — go to <a href="/admin/pages">Admin &rsaquo; Pages</a> and create pages for your site.</li>
        <li><strong>Change your logo and colours</strong> — go to <a href="/admin/theme">Admin &rsaquo; Theme</a>.</li>
        <li><strong>Manage navigation</strong> — add links via <a href="/admin/navigation">Admin &rsaquo; Navigation</a>.</li>
        <li><strong>Add users</strong> — invite team members via <a href="/admin/users">Admin &rsaquo; Users</a>.</li>
    </ul>
</div>

<div class="app-section">
    <h2>Need help?</h2>
    <p>Contact <a href="/helpdesk">our HelpDesk</a> or visit the <a href="/ENCY">knowledge base</a>.</p>
</div>

</div>
</div>
</div>
END_TT
}

sub _cf_secrets_path {
    my $home = $ENV{HOME} || '/root';
    my $dir  = $ENV{COMSERV_SECRETS_DIR} || File::Spec->catfile($home, '.comserv', 'secrets');
    return File::Spec->catfile($dir, 'cloudflare.json');
}

sub _db_get_secret {
    my ($self, $c, $key) = @_;
    my $row = eval { $c->model('DBEncy')->resultset('AppSecret')->find({ secret_key => $key }) };
    return $row ? $row->secret_value : undef;
}

sub _db_set_secret {
    my ($self, $c, $key, $value, $desc) = @_;
    my $who = $c->session->{username} || 'admin';
    my $rs  = $c->model('DBEncy')->resultset('AppSecret');
    my $row = $rs->find({ secret_key => $key });
    if ($row) {
        $row->update({ secret_value => $value, description => $desc || '', updated_by => $who });
    } else {
        $rs->create({ secret_key => $key, secret_value => $value, description => $desc || '', updated_by => $who });
    }
}

sub cf_settings :Path('cf_settings') :Args(0) {
    my ($self, $c) = @_;

    my $db_token = $self->_db_get_secret($c, 'cloudflare_api_token') // '';
    my $db_email = $self->_db_get_secret($c, 'cloudflare_email')     // '';

    if ($c->req->method eq 'POST') {
        my $p     = $c->req->params;
        my $token = $p->{api_token} // '';
        $token =~ s/^\s+|\s+$//g;
        my $email = $p->{email} // $db_email;

        if ($token) {
            if ($token =~ /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i) {
                $c->flash->{error_msg} = 'That looks like a Cloudflare Tunnel token (UUID format), not a DNS API token. '
                    . 'Create a DNS API token at: https://dash.cloudflare.com/profile/api-tokens '
                    . '— use the "Edit zone DNS" template with Zone:DNS:Edit permissions.';
                $c->response->redirect($c->uri_for($self->action_for('cf_settings')));
                return;
            }
            if (length($token) < 30) {
                $c->flash->{error_msg} = 'Token too short — Cloudflare API tokens are typically 40+ characters.';
                $c->response->redirect($c->uri_for($self->action_for('cf_settings')));
                return;
            }
        }

        eval {
            if ($token) {
                $self->_db_set_secret($c, 'cloudflare_api_token', $token,
                    'Cloudflare API token for DNS management');
            }
            $self->_db_set_secret($c, 'cloudflare_email', $email,
                'Cloudflare account email') if $email;
        };
        if ($@) {
            $c->flash->{error_msg} = "Failed to save: $@";
        } else {
            $c->flash->{success_msg} = 'Cloudflare credentials saved to the database (app_secrets table) — shared across all branches and servers.';
        }
        $c->response->redirect($c->uri_for($self->action_for('cf_settings')));
        return;
    }

    my $token_set = $db_token && length($db_token) > 20;
    $c->stash(
        template  => 'admin/site_provisioning/cf_settings.tt',
        cf_email  => $db_email,
        token_set => $token_set,
    );
}

__PACKAGE__->meta->make_immutable;
1;
