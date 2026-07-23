package Comserv::Controller::Newsletter;
use Moose;
use namespace::autoclean;
use Try::Tiny;
# Perl 5.40: namespace::autoclean strips imported try/catch; re-import after
# its BEGIN so the Try::Tiny idiom keeps working (perl-try-tiny-autoclean-debug).
INIT { Try::Tiny->import }
use JSON qw(encode_json decode_json);
use Digest::SHA qw(sha256_hex);
use POSIX qw(strftime);
use File::Find qw(find);
use File::Basename qw(basename);
use Comserv::Util::Logging;

BEGIN { extends 'Catalyst::Controller'; }

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance },
);

# ─── Public archive: all newsletters visible to this SiteName ───────────────

sub archive :Path('/newsletters') :Args(0) {
    my ($self, $c) = @_;

    my $sitename   = $self->_get_sitename($c);
    my $user_roles = $c->session->{roles} || 'public';
    my $is_admin   = $self->_has_newsletter_admin_role($c);

    my ($publication_tree, $shared_by_site) = $self->_fetch_archive_publications(
        $c, $sitename, $user_roles, $is_admin
    );

    $c->stash(
        sitename          => $sitename,
        publication_tree  => $publication_tree,
        shared_by_site    => $shared_by_site,
        is_admin          => $is_admin,
        page_title        => 'Newsletters',
        ScriptDisplayName => 'Newsletters',
        template          => 'newsletter/archive.tt',
    );
    $c->forward($c->view('TT'));
}

# ─── Admin: list newsletter pages + campaigns for this site ─────────────────

sub index :Path('/mail/newsletters') :Args(0) {
    my ($self, $c) = @_;

    unless ($self->_has_newsletter_admin_role($c)) {
        $c->flash->{error_msg} = 'Admin or editor access required.';
        $c->res->redirect($c->uri_for('/newsletters'));
        return;
    }

    my $sitename = $self->_get_sitename($c);
    my $site_id  = $self->_get_site_id($c);
    my $is_csc   = ($sitename eq 'CSC');
    $self->_ensure_newsletter_list($c, $site_id) if $site_id;
    # No auto-create publications on page load — newsletters are created only via + New Newsletter.
    if ($is_csc) {
        $self->_retire_duplicate_publications($c);
        $self->_retire_auto_dns_publications($c);
        $self->_link_orphan_issues_to_publications($c);
    }

    my $newsletter_tree = $self->_build_admin_newsletter_tree($c, $sitename, $is_csc);

    my @campaigns;
    eval {
        my $rs = $c->model('DBEncy')->resultset('MailingListCampaign')->search(
            {
                'mailing_list.site_id' => $site_id,
            },
            {
                prefetch => [qw/mailing_list page/],
                order_by => { -desc => 'sent_at' },
                rows     => 50,
            },
        );
        while (my $camp = $rs->next) {
            push @campaigns, {
                id              => $camp->id,
                subject         => $camp->subject,
                sent_at         => $camp->sent_at,
                recipient_count => $camp->recipient_count,
                success_count   => $camp->success_count // 0,
                fail_count      => $camp->fail_count    // 0,
                status          => $camp->status,
                page_code       => ($camp->page ? $camp->page->page_code : ''),
                page_title      => ($camp->page ? $camp->page->title       : ''),
                list_name       => ($camp->mailing_list ? $camp->mailing_list->name : ''),
            };
        }
    };

    $c->stash(
        sitename         => $sitename,
        is_csc           => $is_csc,
        newsletter_tree  => $newsletter_tree,
        campaigns        => \@campaigns,
        template         => 'newsletter/admin_index.tt',
    );
    $c->forward($c->view('TT'));
}

# ─── Admin: create / edit newsletter publication (container) ────────────────

sub publication_create :Path('/mail/newsletter/publication/create') :Args(0) {
    my ($self, $c) = @_;
    unless ($self->_has_newsletter_admin_role($c)) {
        $c->flash->{error_msg} = 'Admin or editor access required.';
        $c->res->redirect($c->uri_for('/newsletters'));
        return;
    }

    my $sitename = $self->_get_sitename($c);
    my @available_sites = $self->_available_sites_for_admin($c, $sitename);

    if ($c->req->method eq 'POST') {
        my $target_site = $c->req->param('sitename') || $sitename;
        my $title       = $c->req->param('title')       // '';
        my $description = $c->req->param('description') // '';
        my $nl_series   = $c->req->param('nl_series')   // 'hosting';
        my $visible_to  = $c->req->param('nl_visible_to') // 'hosting_members';
        my $share_with  = $c->req->param('share_with')  // '';
        my $custom      = $c->req->param('nl_custom_label') // '';

        $title =~ s/^\s+|\s+$//g;
        $description =~ s/^\s+|\s+$//g;

        unless ($title && $description) {
            my $target_site = $c->req->param('sitename') || $sitename;
            my $target_site_id = $self->_get_site_id_for_sitename($c, $target_site);
            $c->stash(
                error_msg => 'Newsletter name and description are required.',
                form_data => { map { $_ => scalar($c->req->param($_)) }
                    qw/title description sitename nl_series nl_visible_to share_with nl_custom_label
                       nl_mailing_list_id create_subscription_list subscription_list_name/ },
                available_sites   => \@available_sites,
                newsletter_series => [ $self->_newsletter_series_list() ],
                mailing_lists     => [ $self->_fetch_site_mailing_lists($c, $target_site_id) ],
                sitename => $sitename, is_csc => ($sitename eq 'CSC'),
                template => 'newsletter/publication_create.tt',
            );
            $c->forward($c->view('TT'));
            return;
        }

        unless ($self->_can_admin_sitename($c, $target_site)) {
            $c->flash->{error_msg} = "You can only create newsletters for $sitename.";
            $c->res->redirect($c->uri_for('/mail/newsletters'));
            return;
        }

        my $pub_meta = $self->_build_publication_meta_from_form($nl_series, $custom, $visible_to);
        $self->_apply_publication_mailing_list($c, $pub_meta, $target_site, $title, $description, {
            mailing_list_id => $c->req->param('nl_mailing_list_id'),
            create_list     => $c->req->param('create_subscription_list'),
            list_name       => $c->req->param('subscription_list_name'),
        });
        $self->_ensure_publication_subscription_list($c, $pub_meta, $target_site, $title, $description);
        my $page_code = $self->_build_publication_page_code($pub_meta, $title);
        my $exists = $c->model('DBEncy')->resultset('Page')->search(
            { sitename => $target_site, page_code => $page_code }, { rows => 1 },
        )->single;
        $page_code .= '-b' . int(rand(900) + 100) if $exists;

        $share_with = 'all' if $visible_to eq 'all' && !$share_with;

        eval {
            my $page = $c->model('DBEncy')->resultset('Page')->create({
                sitename    => $target_site,
                menu        => 'newsletter',
                page_code   => $page_code,
                page_type   => 'newsletter_pub',
                title       => $title,
                body        => '<p>' . $self->_escape_html($description) . '</p>',
                description => $description,
                keywords    => $self->_encode_publication_meta($pub_meta),
                status      => 'active',
                roles       => 'public',
                share_with  => $share_with,
                link_order  => 0,
                created_by  => $c->session->{username} || 'admin',
            });
            my $link = $self->_mailing_list_link_status($c, $target_site, $pub_meta);
            my $list_msg = $link->{linked}
                ? qq{ Public list "$link->{name}" is on Subscribe and My Subscriptions.}
                : ' Could not create a subscription list — edit the newsletter to fix.';
            $c->flash->{success_msg} = "Newsletter \"$title\" created.$list_msg Add issues below it.";
            $c->res->redirect($c->uri_for('/mail/newsletters'));
        };
        if ($@) {
            $c->stash(
                error_msg => "Could not create newsletter: $@",
                form_data => { title => $title, description => $description },
                available_sites => \@available_sites,
                newsletter_series => [ $self->_newsletter_series_list() ],
                sitename => $sitename, is_csc => ($sitename eq 'CSC'),
                template => 'newsletter/publication_create.tt',
            );
            $c->forward($c->view('TT'));
        }
        return;
    }

    my $target_site_id = $self->_get_site_id_for_sitename($c, $sitename);
    $c->stash(
        available_sites   => \@available_sites,
        newsletter_series => [ $self->_newsletter_series_list() ],
        mailing_lists     => [ $self->_fetch_site_mailing_lists($c, $target_site_id) ],
        form_data         => {
            nl_series => 'hosting', nl_visible_to => 'hosting_members',
            create_subscription_list => 1,
        },
        sitename          => $sitename,
        is_csc            => ($sitename eq 'CSC'),
        template          => 'newsletter/publication_create.tt',
    );
    $c->forward($c->view('TT'));
}

sub publication_edit :Path('/mail/newsletter/publication/edit') :Args(1) {
    my ($self, $c, $page_code) = @_;
    unless ($self->_has_newsletter_admin_role($c)) {
        $c->flash->{error_msg} = 'Admin or editor access required.';
        $c->res->redirect($c->uri_for('/newsletters'));
        return;
    }

    my $sitename = $self->_get_sitename($c);
    my $pub      = $self->_find_newsletter_publication($c, $page_code, $sitename);
    unless ($pub && $self->_can_admin_publication($c, $pub, $sitename)) {
        $c->flash->{error_msg} = 'Newsletter not found or access denied.';
        $c->res->redirect($c->uri_for('/mail/newsletters'));
        return;
    }

    if ($c->req->method eq 'POST') {
        eval {
            my $nl_series  = $c->req->param('nl_series')  // '';
            my $visible_to = $c->req->param('nl_visible_to') // 'hosting_members';
            my $custom     = $c->req->param('nl_custom_label') // '';
            my $pub_meta   = $self->_build_publication_meta_from_form($nl_series, $custom, $visible_to);
            my $pub_title = $c->req->param('title') // $pub->title;
            my $pub_desc  = $c->req->param('description') // $pub->description;
            $self->_apply_publication_mailing_list($c, $pub_meta, $pub->sitename,
                $pub_title, $pub_desc, {
                    mailing_list_id => $c->req->param('nl_mailing_list_id'),
                    create_list     => $c->req->param('create_subscription_list'),
                    list_name       => $c->req->param('subscription_list_name'),
                });
            $self->_ensure_publication_subscription_list($c, $pub_meta, $pub->sitename, $pub_title, $pub_desc);
            $pub->update({
                title       => $c->req->param('title')       // $pub->title,
                description => $c->req->param('description') // $pub->description,
                body        => '<p>' . $self->_escape_html($c->req->param('description') // $pub->description) . '</p>',
                share_with  => $c->req->param('share_with')  // ($pub->share_with // ''),
                status      => $c->req->param('status')      // $pub->status,
                keywords    => $self->_encode_publication_meta($pub_meta),
            });
            $c->flash->{success_msg} = 'Newsletter updated.';
            $c->res->redirect($c->uri_for('/mail/newsletters'));
        };
        if ($@) {
            $c->stash(error_msg => "Save failed: $@");
        } else {
            return;
        }
    }

    my $pub_meta = $self->_parse_publication_meta($pub->keywords, $pub->title);
    my $pub_site_id = $self->_get_site_id_for_sitename($c, $pub->sitename);
    $c->stash(
        publication       => $pub,
        pub_meta          => $pub_meta,
        newsletter_series => [ $self->_newsletter_series_list() ],
        mailing_lists     => [ $self->_fetch_site_mailing_lists($c, $pub_site_id) ],
        mailing_list_link => $self->_mailing_list_link_status($c, $pub->sitename, $pub_meta),
        sitename          => $sitename,
        is_csc            => ($sitename eq 'CSC'),
        template          => 'newsletter/publication_edit.tt',
    );
    $c->forward($c->view('TT'));
}

# ─── Admin: create draft newsletter issue ───────────────────────────────────

sub issue_create :Path('/mail/newsletter/issue/create') :Args(0) {
    my ($self, $c) = @_;
    return $self->create($c);
}

sub create :Path('/mail/newsletter/create') :Args(0) {
    my ($self, $c) = @_;

    unless ($self->_has_newsletter_admin_role($c)) {
        $c->flash->{error_msg} = 'Admin or editor access required.';
        $c->res->redirect($c->uri_for('/newsletters'));
        return;
    }

    my $sitename = $self->_get_sitename($c);
    my @available_sites;
    if ($sitename eq 'CSC') {
        my $sites = eval { $c->model('Site')->get_all_sites($c) };
        @available_sites = $sites ? map { $_->name } @$sites : ($sitename);
    } else {
        @available_sites = ($sitename);
    }

    if ($c->req->method eq 'POST') {
        my $title       = $c->req->param('title')       // '';
        my $body        = $c->req->param('body')        // '';
        my $target_site = $c->req->param('sitename')    || $sitename;
        my $roles       = $c->req->param('roles')       || 'public';
        my $share_with  = $c->req->param('share_with')  // '';
        my $page_code   = $c->req->param('page_code')   // '';
        my $description = $c->req->param('description') // '';
        my $pub_id      = $c->req->param('nl_pub_id')   // '';
        my $nl_series   = $c->req->param('nl_series')   // 'hosting';
        my $nl_version  = $c->req->param('nl_version')  // '';
        my $custom_label = $c->req->param('nl_custom_label') // '';

        $title =~ s/^\s+|\s+$//g;
        unless ($pub_id) {
            $c->stash(
                error_msg => 'Select which newsletter this issue belongs to.',
                form_data => { map { $_ => scalar($c->req->param($_)) }
                    qw/title body sitename roles share_with page_code description nl_pub_id nl_series nl_version nl_custom_label/ },
                available_sites    => \@available_sites,
                publications       => $self->_fetch_publications_for_admin($c, $sitename),
                feature_guides     => $self->_feature_guides_arrayref($c, $sitename),
                newsletter_series  => [ $self->_newsletter_series_list() ],
                sitename => $sitename, is_csc => ($sitename eq 'CSC'),
                template => 'newsletter/create.tt',
            );
            $c->forward($c->view('TT'));
            return;
        }
        unless ($body) {
            $c->stash(
                error_msg  => 'Newsletter content is required.',
                form_data  => { map { $_ => scalar($c->req->param($_)) }
                    qw/title body sitename roles share_with page_code description nl_series nl_version nl_custom_label/ },
                available_sites   => \@available_sites,
                feature_guides    => $self->_feature_guides_arrayref($c, $sitename),
                newsletter_series => [ $self->_newsletter_series_list() ],
                sitename          => $sitename,
                is_csc            => ($sitename eq 'CSC'),
                template          => 'newsletter/create.tt',
            );
            $c->forward($c->view('TT'));
            return;
        }

        if ($sitename ne 'CSC' && $target_site ne $sitename) {
            $c->stash(
                error_msg  => "You can only create newsletters for $sitename.",
                form_data  => { title => $title, body => $body },
                available_sites   => \@available_sites,
                feature_guides    => $self->_feature_guides_arrayref($c, $sitename),
                newsletter_series => [ $self->_newsletter_series_list() ],
                sitename          => $sitename,
                is_csc            => 0,
                template          => 'newsletter/create.tt',
            );
            $c->forward($c->view('TT'));
            return;
        }

        my $publication = $self->_find_publication_by_id($c, $pub_id, $sitename);
        unless ($publication && $self->_can_admin_publication($c, $publication, $sitename)) {
            $c->flash->{error_msg} = 'Invalid newsletter selected.';
            $c->res->redirect($c->uri_for('/mail/newsletter/create'));
            return;
        }
        my $pub_meta = $self->_parse_publication_meta($publication->keywords, $publication->title);
        my $meta = $self->_build_newsletter_meta_from_form(
            $c, $target_site, $pub_meta->{series}, $nl_version, $custom_label, $publication
        );
        $title = $self->_build_newsletter_title($meta)
            unless $title =~ /\S/;
        $description = $self->_build_newsletter_description($meta)
            unless $description =~ /\S/;
        $page_code = $self->_normalize_newsletter_page_code($page_code)
            || $self->_build_newsletter_page_code($meta);
        my $exists = $c->model('DBEncy')->resultset('Page')->search(
            { sitename => $target_site, page_code => $page_code },
            { rows => 1 },
        )->single;
        if ($exists) {
            $page_code .= '-b' . int(rand(900) + 100);
        }

        eval {
            my $page = $c->model('DBEncy')->resultset('Page')->create({
                sitename    => $target_site,
                menu        => 'newsletter',
                page_code   => $page_code,
                page_type   => 'newsletter',
                title       => $title,
                body        => $body,
                description => $description,
                keywords    => $self->_encode_newsletter_meta($meta),
                status      => 'draft',
                roles       => $roles,
                share_with  => $share_with,
                link_order  => 0,
                created_by  => $c->session->{username} || 'admin',
            });
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create',
                "Newsletter page created: $page_code for $target_site");
            $c->flash->{success_msg} = "Newsletter draft created.";
            $c->res->redirect($c->uri_for('/mail/newsletter/edit', $page->page_code));
        };
        if ($@) {
            $c->stash(
                error_msg => "Could not create newsletter: $@",
                form_data => { title => $title, body => $body, page_code => $page_code },
                available_sites => \@available_sites,
                feature_guides  => $self->_feature_guides_arrayref($c, $sitename),
                sitename  => $sitename,
                is_csc    => ($sitename eq 'CSC'),
                template  => 'newsletter/create.tt',
            );
            $c->forward($c->view('TT'));
        }
        return;
    }

    my $pub_param = $c->req->param('pub') // $c->req->param('nl_pub_id') // '';
    my @publications = $self->_fetch_publications_for_admin($c, $sitename);
    my $default_pub = $pub_param;
    if (!$default_pub && @publications == 1) {
        $default_pub = $publications[0]{id};
    }

    $c->stash(
        available_sites   => \@available_sites,
        publications      => \@publications,
        sitename          => $sitename,
        is_csc            => ($sitename eq 'CSC'),
        form_data         => { nl_pub_id => $default_pub, nl_series => 'hosting' },
        feature_guides    => $self->_feature_guides_arrayref($c, $sitename),
        newsletter_series => [ $self->_newsletter_series_list() ],
        template          => 'newsletter/create.tt',
    );
    $c->forward($c->view('TT'));
}

# JSON: next version, title, slug, description for create form
sub series_meta :Path('/mail/newsletter/series_meta') :Args(0) {
    my ($self, $c) = @_;

    unless ($self->_has_newsletter_admin_role($c)) {
        $c->response->content_type('application/json; charset=utf-8');
        $c->response->body('{"ok":0,"error":"Admin or editor access required."}');
        $c->response->status(403);
        return;
    }

    my $sitename = $c->req->param('sitename') || $self->_get_sitename($c);
    my $pub_id   = $c->req->param('pub_id')   // $c->req->param('nl_pub_id') // '';
    my $series   = $c->req->param('series')   || 'hosting';
    my $custom   = $c->req->param('custom_label') // '';
    my $publication;
    $publication = $self->_find_publication_by_id($c, $pub_id, $sitename) if $pub_id;
    if ($publication) {
        my $pm = $self->_parse_publication_meta($publication->keywords, $publication->title);
        $series = $pm->{series};
        $sitename = $publication->sitename;
    }
    my $meta = $self->_build_newsletter_meta_from_form(
        $c, $sitename, $series, undef, $custom, $publication
    );

    $c->response->content_type('application/json; charset=utf-8');
    $c->response->body(encode_json({
        ok          => 1,
        series      => $meta->{series},
        series_label => $meta->{series_label},
        version     => $meta->{version},
        audience    => $meta->{audience_label},
        title       => $self->_build_newsletter_title($meta),
        description => $self->_build_newsletter_description($meta),
        page_code   => $self->_build_newsletter_page_code($meta),
        mailing_list => $meta->{mailing_list},
    }));
}

# ─── Admin: edit draft / published newsletter page ───────────────────────────

sub edit :Path('/mail/newsletter/edit') :Args(1) {
    my ($self, $c, $page_code) = @_;

    unless ($self->_has_newsletter_admin_role($c)) {
        $c->flash->{error_msg} = 'Admin or editor access required.';
        $c->res->redirect($c->uri_for('/newsletters'));
        return;
    }

    my $sitename = $self->_get_sitename($c);
    my $page     = $self->_find_newsletter_page($c, $page_code, $sitename, admin => 1);
    unless ($page) {
        $c->flash->{error_msg} = 'Newsletter not found.';
        $c->res->redirect($c->uri_for('/mail/newsletters'));
        return;
    }

    my @available_sites = ($sitename);
    if ($sitename eq 'CSC') {
        my $sites = eval { $c->model('Site')->get_all_sites($c) };
        @available_sites = $sites ? map { $_->name } @$sites : ($sitename);
    }

    if ($c->req->method eq 'POST') {
        my $go_send = $c->req->param('go_send') ? 1 : 0;
        eval {
            my $new_status = $c->req->param('status') // $page->status;
            my $meta = $self->_parse_newsletter_meta($page->keywords, $page->page_code, $page->title);
            my $nl_series  = $c->req->param('nl_series')  // $meta->{series};
            my $nl_version = $c->req->param('nl_version') // $meta->{version};
            my $custom     = $c->req->param('nl_custom_label') // $meta->{custom_label};
            $meta = $self->_build_newsletter_meta_from_form(
                $c, $page->sitename, $nl_series, $nl_version, $custom
            );
            my %update = (
                title       => $c->req->param('title')      // $page->title,
                body        => $c->req->param('body')       // $page->body,
                description => $c->req->param('description') // $page->description,
                roles       => $c->req->param('roles')      // $page->roles,
                share_with  => $c->req->param('share_with') // ($page->share_with // ''),
                status      => $new_status,
                keywords    => $self->_encode_newsletter_meta($meta),
            );
            if (($page->status // '') eq 'draft') {
                my $new_code = $c->req->param('page_code') // '';
                $new_code = $self->_normalize_newsletter_page_code($new_code);
                if ($new_code && $new_code ne ($page->page_code // '')) {
                    my $dup = $c->model('DBEncy')->resultset('Page')->search(
                        { sitename => $page->sitename, page_code => $new_code },
                        { rows => 1 },
                    )->single;
                    die "URL slug already in use: $new_code" if $dup;
                    $update{page_code} = $new_code;
                    $page_code = $new_code;
                }
            }
            $page->update(\%update);
            if ($go_send) {
                $c->flash->{success_msg} = 'Newsletter saved — compose the email to subscribers next.';
                $c->res->redirect($c->uri_for('/mail/newsletter/send', $page->id));
            } else {
                my $msg = 'Newsletter saved.';
                if ($new_status && ($new_status eq 'active' || $new_status eq 'published')) {
                    $msg .= ' Online page is published. When ready, use Send Newsletter to email subscribers.';
                }
                $c->flash->{success_msg} = $msg;
                $c->res->redirect($c->uri_for('/mail/newsletter/edit', $page_code));
            }
        };
        if ($@) {
            # fall through to re-render edit form with error
        } else {
            return;
        }
    }

    my $nl_meta = $self->_parse_newsletter_meta($page->keywords, $page->page_code, $page->title);
    $c->stash(
        page              => $page,
        nl_meta           => $nl_meta,
        sitename          => $sitename,
        is_csc            => ($sitename eq 'CSC'),
        available_sites   => \@available_sites,
        feature_guides    => $self->_feature_guides_arrayref($c, $sitename),
        newsletter_series => [ $self->_newsletter_series_list() ],
        template          => 'newsletter/edit.tt',
    );
    $c->forward($c->view('TT'));
}

# ─── Admin: compose and send newsletter email ───────────────────────────────

sub send :Path('/mail/newsletter/send') :Args(1) {
    my ($self, $c, $page_id) = @_;

    unless ($self->_has_newsletter_admin_role($c)) {
        $c->flash->{error_msg} = 'Admin or editor access required.';
        $c->res->redirect($c->uri_for('/newsletters'));
        return;
    }

    my $sitename = $self->_get_sitename($c);
    my $site_id  = $self->_get_site_id($c);
    my $page     = eval { $c->model('DBEncy')->resultset('Page')->find($page_id) };

    unless ($page && $self->_is_newsletter_page($page)
        && ($sitename eq 'CSC' || $page->sitename eq $sitename)) {
        $c->flash->{error_msg} = 'Newsletter page not found.';
        $c->res->redirect($c->uri_for('/mail/newsletters'));
        return;
    }

    if ($site_id) {
        my $mail = $c->controller('Mail');
        $mail->_sync_default_lists($c, $site_id) if $mail;
    }
    $self->_ensure_newsletter_list($c, $site_id);
    my @mailing_lists = $self->_fetch_site_mailing_lists($c, $site_id);
    my $selected_list_id = $c->req->param('mailing_list_id');
    my $issue_meta = $self->_parse_newsletter_meta($page->keywords, $page->page_code, $page->title);
    my $pub_list_id;
    if ($issue_meta->{pub_id}) {
        my $pub = $self->_find_publication_by_id($c, $issue_meta->{pub_id}, $sitename);
        if ($pub) {
            my $pm = $self->_parse_publication_meta($pub->keywords, $pub->title);
            $pub_list_id = $self->_resolve_mailing_list_id(
                $c, $pub->sitename, $pm->{mailing_list}, $pm->{mailing_list_id}
            );
        }
    }
    unless ($selected_list_id && grep { $_->{id} == $selected_list_id } @mailing_lists) {
        $selected_list_id = $pub_list_id || $self->_default_mailing_list_id(\@mailing_lists);
    }
    my $sub_count = 0;
    for my $ml (@mailing_lists) {
        if ($ml->{id} == $selected_list_id) {
            $sub_count = $ml->{sub_count};
            last;
        }
    }

    my $teaser = $self->_default_teaser($page);

    if ($c->req->method eq 'POST') {
        return $self->_do_send($c, $page, undef, $site_id);
    }

    $c->stash(
        page               => $page,
        mailing_lists      => \@mailing_lists,
        selected_list_id   => $selected_list_id,
        sub_count          => $sub_count,
        teaser             => $teaser,
        read_url           => $self->_absolute_uri($c, $c->uri_for('/page', $page->page_code)),
        template           => 'newsletter/send.tt',
    );
    $c->forward($c->view('TT'));
}

# ─── AI context JSON (form assistant + chat widget) ───────────────────────────

sub ai_context :Path('/mail/newsletter/ai_context') :Args(0) {
    my ($self, $c) = @_;

    unless ($self->_has_newsletter_admin_role($c)) {
        $c->response->content_type('application/json; charset=utf-8');
        $c->response->body('{"ok":0,"error":"Admin or editor access required."}');
        $c->response->status(403);
        return;
    }

    my @guide_ids = $self->_parse_guide_id_params($c);
    my $ctx = $self->build_ai_context($c, guide_ids => \@guide_ids);
    $c->response->content_type('application/json; charset=utf-8');
    $c->response->body(encode_json({ ok => 1, context => $ctx }));
}

# JSON list of curated member how-to sources (pages + Documentation changelogs)
sub feature_guides :Path('/mail/newsletter/feature_guides') :Args(0) {
    my ($self, $c) = @_;

    unless ($self->_has_newsletter_admin_role($c)) {
        $c->response->content_type('application/json; charset=utf-8');
        $c->response->body('{"ok":0,"error":"Admin or editor access required."}');
        $c->response->status(403);
        return;
    }

    my $sitename = $self->_get_sitename($c);
    my @guides = $self->_list_available_feature_guides($c, $sitename);
    $c->response->content_type('application/json; charset=utf-8');
    $c->response->body(encode_json({ ok => 1, guides => \@guides }));
}

# Return HTML fragments for selected guides (insert into newsletter body without AI)
sub feature_guide_body :Path('/mail/newsletter/feature_guide_body') :Args(0) {
    my ($self, $c) = @_;

    unless ($self->_has_newsletter_admin_role($c)) {
        $c->response->content_type('application/json; charset=utf-8');
        $c->response->body('{"ok":0,"error":"Admin or editor access required."}');
        $c->response->status(403);
        return;
    }

    my $sitename = $self->_get_sitename($c);
    my @guide_ids = $self->_parse_guide_id_params($c);
    unless (@guide_ids) {
        $c->response->content_type('application/json; charset=utf-8');
        $c->response->body(encode_json({ ok => 0, error => 'No guides selected.' }));
        return;
    }

    my ($html, $count) = $self->_build_feature_guide_html($c, $sitename, \@guide_ids);
    $c->response->content_type('application/json; charset=utf-8');
    $c->response->body(encode_json({
        ok    => 1,
        html  => $html,
        count => $count,
        ids   => \@guide_ids,
    }));
}

# Build live application data for newsletter drafting (shared by form AI + chat)
sub build_ai_context {
    my ($self, $c, %opts) = @_;

    my $sitename = $self->_get_sitename($c);
    my $site_id  = $self->_get_site_id($c);
    my @sections;
    my $since_sql = $self->_newsletter_since_sql($c, $site_id);

    push @sections, "SITE: $sitename (site_id=" . ($site_id // 'unknown') . ")";
    push @sections, $self->_build_ground_truth_navigation();
    push @sections, "NEWSLETTER URLS:";
    push @sections, "  - Public archive (members & guests): /newsletters";
    push @sections, "  - Subscribe: /mail/subscribe";
    push @sections, "  - Admin manage: /mail/newsletters";
    push @sections, "  - Create issue: /mail/newsletter/create";
    push @sections, "  - Each issue is a permanent page at /page/{page_code}";

    my @guide_ids = @{ $opts{guide_ids} // [] };
    my @guides = $self->_list_available_feature_guides($c, $sitename, since => $since_sql);
    if (@guide_ids) {
        my %want = map { $_ => 1 } @guide_ids;
        @guides = grep { $want{ $_->{id} } } @guides;
    } else {
        @guides = grep { $_->{is_new_since_last_send} } @guides;
    }

    my @guide_ctx = $self->_build_feature_guide_context_lines(\@guides);
    if (@guide_ctx) {
        push @sections, @guide_ctx;
    } else {
        push @sections,
            "FEATURE GUIDES: none selected or none marked newsletter_include since $since_sql.",
            "  ACTION: check 'Include from feature guides' on the create form, or add a member how-to",
            "  (page_type=feature_guide or Documentation changelog with newsletter_include=yes).";
    }

    eval {
        my $last = $c->model('DBEncy')->resultset('MailingListCampaign')->search(
            { 'mailing_list.site_id' => $site_id, status => 'sent' },
            { prefetch => [qw/mailing_list page/], order_by => { -desc => 'sent_at' }, rows => 1 },
        )->single;
        if ($last) {
            push @sections, "LAST SENT NEWSLETTER:";
            push @sections, "  Subject: " . ($last->subject // '');
            push @sections, "  Sent at: " . ($last->sent_at   // '');
            push @sections, "  Recipients: " . ($last->success_count // 0);
            if ($last->page) {
                push @sections, "  Page: /page/" . $last->page->page_code . " — " . $last->page->title;
            }
        } else {
            push @sections, "LAST SENT NEWSLETTER: none yet for this site.";
        }
    };

    eval {
        my %cond = %{ $self->_newsletter_search_cond($sitename, include_drafts => 1) };
        $cond{sitename} = $sitename unless $sitename eq 'CSC';
        my @pages = $c->model('DBEncy')->resultset('Page')->search(
            \%cond,
            { order_by => { -desc => 'updated_at' }, rows => 8 },
        )->all;
        if (@pages) {
            push @sections, "RECENT NEWSLETTER PAGES:";
            for my $p (@pages) {
                push @sections, sprintf "  - [%s] %s — /page/%s (updated %s)",
                    $p->status, $p->title, $p->page_code, ($p->updated_at // '');
            }
        }
    };

    my $git_since = $since_sql;
    my $repo = '/home/shanta/PycharmProjects/comserv2';
    if (-d "$repo/.git" && !@guide_ctx) {
        my @git_detail = $self->_build_git_change_detail($repo, $git_since);
        if (@git_detail) {
            push @sections, "GIT HINTS (fallback only — prefer FEATURE GUIDES above):";
            push @sections, @git_detail;
        }
        my @owner_guide = $self->_build_site_owner_feature_guide($repo, $git_since, $sitename);
        push @sections, @owner_guide if @owner_guide;
    }

    eval {
        my $schema = $c->model('DBEncy')->schema;
        if ($schema && $schema->resultset('Todo')) {
            my $rs = $schema->resultset('Todo')->search(
                { sitename => $sitename },
                { order_by => { -desc => 'record_id' }, rows => 25 },
            );
            my @todo_lines;
            while (my $t = $rs->next) {
                my $subj = $t->subject // '';
                $subj = substr($subj, 0, 120) if $subj;
                $subj ||= substr($t->description // 'task', 0, 120);
                push @todo_lines, sprintf "  - %s (due: %s, start: %s)",
                    $subj,
                    ($t->due_date // 'none'), ($t->start_date // 'none');
            }
            if (@todo_lines) {
                push @sections, "ACTIVE TODOS / PLANNING (recent updates):";
                push @sections, @todo_lines;
            }
        }
    };

    my $today = strftime('%Y-%m-%d', localtime);

    eval {
        my $schema = $c->model('DBEncy')->schema;
        return unless $schema && $schema->resultset('DailyPlan');

        my @plan_lines;

        # Today's daily log (calendar planning for this session)
        my $today_log = $schema->resultset('DailyPlan')->search(
            { sitename => $sitename, plan_name => { -like => "Daily Log $today%" } },
            { rows => 1 },
        )->single;
        if ($today_log) {
            push @plan_lines, "  TODAY ($today) — Daily Log:";
            my @entries = $schema->resultset('DailyPlanEntry')->search(
                { plan_id => $today_log->id },
                { order_by => { -asc => 'id' } },
            )->all;
            if (@entries) {
                for my $e (@entries) {
                    my $desc = substr($e->description // '', 0, 100);
                    $desc = " — $desc" if $desc;
                    push @plan_lines, sprintf "    · [%s/%s] %s%s",
                        $e->entry_type, $e->status, ($e->title // ''), $desc;
                }
            } else {
                push @plan_lines, "    (no entries yet)";
            }
        }

        # Plans and entries since last newsletter
        my $plan_rs = $schema->resultset('DailyPlan')->search(
            {
                sitename => $sitename,
                last_modified => { '>=', $since_sql },
            },
            { order_by => { -desc => 'last_modified' }, rows => 12 },
        );
        while (my $plan = $plan_rs->next) {
            next if $today_log && $plan->id == $today_log->id;
            push @plan_lines, sprintf "  - %s (status: %s, modified: %s)",
                $plan->plan_name, $plan->status, ($plan->last_modified // '');
            if ($plan->plan_description) {
                my $pd = substr($plan->plan_description, 0, 150);
                push @plan_lines, "      $pd";
            }
            my @entries = $schema->resultset('DailyPlanEntry')->search(
                { plan_id => $plan->id },
                { order_by => { -desc => 'created_at' }, rows => 6 },
            )->all;
            for my $e (@entries) {
                my $desc = substr($e->description // '', 0, 80);
                $desc = " — $desc" if $desc;
                push @plan_lines, sprintf "      · [%s] %s%s",
                    $e->status, ($e->title // ''), $desc;
            }
        }

        if (@plan_lines) {
            push @sections, "PLANNING CALENDAR (since $since_sql):";
            push @sections, @plan_lines;
        }
    };

    push @sections, "PLANNING DASHBOARD: /planning/daily — full calendar view";
    push @sections, $self->_newsletter_ai_writing_instructions($sitename);

    my $out = join("\n", @sections);
    return length($out) > 16000 ? substr($out, 0, 15997) . '...' : $out;
}

# Run a git command in the repo root; returns chomped lines.
sub _run_git_lines {
    my ($self, $repo, $cmd_tail) = @_;
    return () unless $repo && -d "$repo/.git";
    my @lines = eval {
        my $cmd = qq{cd "$repo" && $cmd_tail 2>/dev/null};
        split /\n/, `$cmd`;
    };
    chomp @lines;
    return grep { defined $_ && $_ ne '' } @lines;
}

# Detailed git history + changed files for AI analysis (not for end-user copy-paste).
sub _build_git_change_detail {
    my ($self, $repo, $since) = @_;
    my @out;
    my @commits = $self->_run_git_lines($repo,
        qq{git log --since="$since" --format='%h|%s' -30 -- Comserv/});
    if (@commits) {
        push @out, "CODE COMMITS SINCE $since (hash|subject — for AI analysis only):";
        push @out, map { "  $_" } @commits;
    }

    my @files = $self->_run_git_lines($repo,
        qq{git log --since="$since" --name-only --pretty=format: -- Comserv/ | sort -u});
    @files = grep { $_ !~ /^\s*$/ } @files;
    if (@files) {
        push @out, "FILES CHANGED (" . scalar(@files) . " paths):";
        my $max = @files > 35 ? 35 : scalar(@files);
        push @out, map { "  $_" } @files[0 .. $max - 1];
        push @out, "  ... and " . (scalar(@files) - $max) . " more" if @files > $max;
    }

    my @stat = $self->_run_git_lines($repo,
        qq{git log --since="$since" --stat --oneline -12 -- Comserv/});
    if (@stat) {
        push @out, "CHANGE SIZE (recent commits):";
        push @out, map { "  $_" } @stat;
    }

    unless (@commits || @files) {
        push @out, "CODE CHANGES: no Comserv/ commits since $since.";
    }
    return @out;
}

# Map changed paths to member/site-owner language the AI must expand in the newsletter body.
sub _build_site_owner_feature_guide {
    my ($self, $repo, $since, $sitename) = @_;

    my @files = $self->_run_git_lines($repo,
        qq{git log --since="$since" --name-only --pretty=format: -- Comserv/ | sort -u});
    return () unless @files;

    my $file_blob = join("\n", @files);
    my (@features, %seen);

    my @rules = (
        [ qr{Controller/Planning\.pm|planning/daily|DailyPlan|todo/day|TopDropListPlanning}i,
          'Planning (verified — only if this section appears below)',
          "VERIFIED: Planning menu (top nav) → /planning/daily with tabs: Daily Priorities (#today-work), Daily Schedule (#daily-schedule), Week/Month views, Planning Board, Gantt.\n"
        . "  VERIFIED: Start Day / End Day buttons run morning audit and daily log (/planning/daily_log).\n"
        . "  VERIFIED: Daily log entries stored per site; todos at /todo and Planning → Todo List.\n"
        . "  NOT IN APP: there is no 'Site Tools' menu, no standalone 'Daily Priority' app, no 'Add Event' wizard, no automatic email reminders toggle for priorities." ],
        [ qr{Controller/Newsletter\.pm|root/newsletter/|newsletter_view}i,
          'Newsletters (verified — only if this section appears below)',
          "VERIFIED: Read archive at /newsletters (Member menu → Newsletters).\n"
        . "  VERIFIED: Editors use /mail/newsletters → Create → /mail/newsletter/create (HTML editor + live preview + AI Form Assistant).\n"
        . "  VERIFIED: Send flow: edit draft → Send Newsletter → email teaser + link to permanent /page/{slug}.\n"
        . "  VERIFIED: Subscribe at /mail/subscribe; Main → Mail Services → Newsletters.\n"
        . "  NOT IN APP: no 'Marketing' menu, no pre-built newsletter templates library, no one-click future scheduling — send is from the Send Newsletter screen when ready." ],
        [ qr{TopDropListMember|membership/index}i,
          'Member menu & membership',
          "Members find site services from the Member dropdown — now includes Newsletters and mailing-list links.\n"
        . "  WHERE: top nav → Member → Newsletters, Subscribe, or Manage Newsletters (editors)." ],
        [ qr{Controller/AI\.pm|ai_form_assistant|local-chat}i,
          'AI assistant',
          "AI chat widget and Form Assistant help draft content and navigate the application.\n"
        . "  WHERE: floating chat on every page; AI Form Assistant on create/edit forms (newsletters, pages, todos).\n"
        . "  USE: ask \"take me to newsletters\" or use shortcuts on the newsletter create form." ],
        [ qr{Controller/Mail\.pm|root/mail/}i,
          'Mail & mailing lists',
          "Mail dashboard for subscriptions, webmail links, and newsletter archive.\n"
        . "  WHERE: Main → Mail (/mail); subscribe at /mail/subscribe; manage lists when logged in." ],
        [ qr{Controller/Todo\.pm|root/todo/}i,
          'Todos & projects',
          "Task and project tracking for site work — visible in planning and todo lists.\n"
        . "  WHERE: /todo — day/week/month views; link planning items to active projects." ],
        [ qr{Navigation/TopDropListMain}i,
          'Main menu navigation',
          "Main menu Mail Services section lists Newsletters, subscribe, and manage links." ],
    );

    for my $rule (@rules) {
        my ($pattern, $title, $detail) = @$rule;
        next unless $file_blob =~ $pattern;
        next if $seen{$title}++;
        push @features, "FEATURE AREA: $title";
        push @features, $detail;
    }

    return () unless @features;

    my @out = (
        "SITE-OWNER FEATURE GUIDE — CODE-BACKED ONLY (from git file changes since last newsletter):",
        "  CRITICAL: Write newsletter sections ONLY for 'FEATURE AREA' blocks listed below.",
        "  If Planning or Newsletters is NOT listed below, do NOT write about that topic at all.",
        "  Use VERIFIED lines only; never claim NOT IN APP items exist. Ignore generic documentation elsewhere.",
        "  Audience: hosting customers and members of $sitename.",
        @features,
    );
    return @out;
}

# Always-included ground truth so the model cannot invent menus from docs or other products.
sub _build_ground_truth_navigation {
    my ($self) = @_;
    return join "\n",
        "VERIFIED APP NAVIGATION (use ONLY these paths in the newsletter — never invent menus):",
        "  Top nav → Planning → /planning/daily",
        "    · Daily Priorities tab: /planning/daily#today-work",
        "    · Daily Schedule tab: /planning/daily#daily-schedule",
        "    · Week / Month / Planning Board / Gantt tabs on same page",
        "    · Start Day / End Day buttons (morning audit + daily log)",
        "  Top nav → Planning → Todo List: /todo",
        "  Top nav → Member → Newsletters: /newsletters",
        "  Top nav → Member → Join Mailing List / My Email Subscriptions: /mail/subscribe, /mail/my_subscriptions",
        "  Top nav → Main → Mail Services → Newsletters, Manage Newsletters: /newsletters, /mail/newsletters",
        "  Top nav → Main → Mail: /mail",
        "  Editors: /mail/newsletter/create (HTML editor + preview + AI assistant), Send from edit screen",
        "",
        "FORBIDDEN IN NEWSLETTER BODY (these do NOT exist in this application):",
        "  - Menus: 'Site Tools', 'Marketing', 'Daily Priority' (as a separate app)",
        "  - Features: newsletter templates library, schedule-send for a future date, 'Add Event' wizard,",
        "    drag-to-reorder for end-user priority lists, automatic email reminder toggles on priorities",
        "  - Prefer curated FEATURE GUIDES (member how-to pages/docs) over git inference.";
}

sub _newsletter_ai_writing_instructions {
    my ($self, $sitename) = @_;
    return join "\n",
        "AI WRITING RULES FOR NEWSLETTER BODY HTML:",
        "  - PRIMARY source: FEATURE GUIDES section — copy/adapt member how-to text and links from there.",
        "  - Do NOT invent features from git when FEATURE GUIDES are present.",
        "  - Keep every <a href=\"...\"> from the guides; paths must be real (/planning/daily, /newsletters, /page/...).",
        "  - One <h2> per included guide; intro paragraph optional; then steps/lists from the guide excerpt.",
        "  - VERIFIED APP NAVIGATION is for cross-checking menu names only — not for inventing new content.",
        "  - Write for site owners of $sitename — no git, file paths, or developer terms in body.",
        "  - If no guides selected, say briefly what is new and link to /newsletters only — do not guess features.",
        "  - description: one plain archive sentence (no HTML).";
}

# ─── Feature guides (curated member how-to — primary newsletter source) ───────

# Must be an arrayref for TT — a bare list in stash() flattens into bogus key/value pairs.
sub _feature_guides_arrayref {
    my ($self, $c, $sitename) = @_;
    return [ $self->_list_available_feature_guides($c, $sitename) ];
}

sub _parse_guide_id_params {
    my ($self, $c) = @_;
    # List context — repeated ?guides=a&guides=b must return all values (scalar param() = first only).
    my @ids = $c->req->param('guides');
    @ids = grep { defined $_ && $_ ne '' } @ids;
    if (@ids == 1 && $ids[0] =~ /,/) {
        @ids = grep { $_ ne '' } split /\s*,\s*/, $ids[0];
    }
    return @ids;
}

sub _newsletter_since_sql {
    my ($self, $c, $site_id) = @_;
    my $since;
    eval {
        my $last = $c->model('DBEncy')->resultset('MailingListCampaign')->search(
            { 'mailing_list.site_id' => $site_id, status => 'sent' },
            { prefetch => 'mailing_list', order_by => { -desc => 'sent_at' }, rows => 1 },
        )->single;
        if ($last && $last->sent_at) {
            $since = "$last->sent_at";
            $since =~ s/T.*$//;
            $since =~ s/ .*$//;
        }
    };
    return $since || strftime('%Y-%m-%d', localtime(time - 30 * 86400));
}

sub _list_available_feature_guides {
    my ($self, $c, $sitename, %opts) = @_;
    my $since = $opts{since} // $self->_newsletter_since_sql($c, $self->_get_site_id($c));

    my @guides;
    push @guides, $self->_fetch_feature_guide_pages($c, $sitename, $since);
    push @guides, $self->_fetch_newsletter_guide_tt_files($c, $since);

    @guides = sort {
        ($b->{sort_date} // '') cmp ($a->{sort_date} // '')
            || ($a->{title} // '') cmp ($b->{title} // '')
    } @guides;

    return @guides;
}

sub _fetch_feature_guide_pages {
    my ($self, $c, $sitename, $since) = @_;
    my @out;
    eval {
        my $rs = $c->model('DBEncy')->resultset('Page')->search(
            {
                page_type => 'feature_guide',
                status    => { -in => [qw/active published/] },
                -or       => [
                    { sitename => $sitename },
                    { sitename => 'CSC' },
                    { share_with => 'all' },
                    { share_with => { -like => "%$sitename%" } },
                ],
            },
            { order_by => { -desc => 'updated_at' } },
        );
        while (my $p = $rs->next) {
            my $updated = $self->_date_only($p->updated_at);
            my $html    = $self->_sanitize_guide_html($p->body // '');
            next unless $html;
            my $title = $self->_decode_basic_entities($p->title // '');
            push @out, {
                id                    => 'page:' . $p->id,
                source                => 'page',
                source_label          => 'Page',
                title                 => $title,
                excerpt               => $self->_html_to_plain_excerpt($html, 220),
                url                   => '/page/' . $p->page_code,
                sort_date             => $updated,
                link_count            => $self->_count_href_links($html),
                is_new_since_last_send => ($updated ge $since) ? 1 : 0,
                html_fragment         => $self->_wrap_guide_fragment($title, $html, '/page/' . $p->page_code),
            };
        }
    };
    return @out;
}

# Stable member how-tos live in Documentation/guides/ (not dated changelog/*.tt files).
sub _fetch_newsletter_guide_tt_files {
    my ($self, $c, $since) = @_;
    my $guides_dir = $c->path_to('root', 'Documentation', 'guides');
    return () unless -d $guides_dir;

    my @out;
    find({
        wanted => sub {
            return unless -f $_;
            my $file = $_;
            return unless $file =~ /\.tt$/;
            return if $file =~ /^(README|_template)\.tt$/i;

            my $path = $File::Find::name;
            my $content;
            eval {
                open my $fh, '<:encoding(UTF-8)', $path or die $!;
                local $/;
                $content = <$fh>;
                close $fh;
            };
            return if $@ || !$content;

            my $meta = $self->_parse_all_meta_from_tt($content);
            my $member_html = $self->_extract_member_howto_html($content);
            my $include = ($meta->{newsletter_include} // '') =~ /^(yes|true|1)$/i
                || (($meta->{audience} // '') =~ /^member$/i
                    && ($meta->{newsletter_include} // '') !~ /^(no|false|0)$/i);
            return unless $include || $member_html;

            $member_html ||= $self->_fallback_member_excerpt_from_changelog($content, $meta);
            return unless $member_html;

            my $key  = basename($file, '.tt');
            my $date = $self->_date_only($meta->{date} // '');
            if (!$date) {
                my $mtime = (stat($path))[9];
                $date = strftime('%Y-%m-%d', localtime($mtime)) if $mtime;
            }
            my $title = $self->_decode_basic_entities($meta->{title} // $key);
            $title =~ s/_/ /g;

            push @out, {
                id                    => 'doc:' . $key,
                source                => 'documentation',
                source_label          => 'Documentation',
                title                 => $title,
                excerpt               => $self->_html_to_plain_excerpt($member_html, 220),
                url                   => '/Documentation/' . $key,
                sort_date             => $date,
                link_count            => $self->_count_href_links($member_html),
                is_new_since_last_send => ($date ge $since) ? 1 : 0,
                html_fragment         => $self->_wrap_guide_fragment($title, $member_html, '/Documentation/' . $key),
            };
        },
        no_chdir => 1,
    }, $guides_dir);

    return @out;
}

sub _parse_all_meta_from_tt {
    my ($self, $content) = @_;
    my $meta = {};
    while ($content =~ /\[% \s* META \s* (.*?) \s* %\]/gsx) {
        my $block = $1;
        while ($block =~ /\b(\w+)\s*=\s*["']([^"']*)["']/g) {
            $meta->{$1} = $2;
        }
    }
    return $meta;
}

sub _extract_member_howto_html {
    my ($self, $content) = @_;
    if ($content =~ /<section\s+class=["']member-how-to["'][^>]*>(.*?)<\/section>/is) {
        return $self->_sanitize_guide_html($1);
    }
    return '';
}

sub _fallback_member_excerpt_from_changelog {
    my ($self, $content, $meta) = @_;
    my $html = '';
    if ($content =~ /<section\s+class=["']changelog-summary["'][^>]*>(.*?)<\/section>/is) {
        $html .= $1;
    }
    if ($meta->{description}) {
        $html = '<p>' . $meta->{description} . '</p>' . $html;
    }
    return $self->_sanitize_guide_html($html);
}

sub _sanitize_guide_html {
    my ($self, $html) = @_;
    $html //= '';
    $html =~ s/<script\b[^>]*>.*?<\/script>//gis;
    $html =~ s/on\w+\s*=\s*["'][^"']*["']//gi;
    $html =~ s/^\s+|\s+$//g;
    return $html;
}

sub _html_to_plain_excerpt {
    my ($self, $html, $max) = @_;
    my $text = $html // '';
    $text =~ s/<[^>]+>/ /g;
    $text =~ s/\s+/ /g;
    $text =~ s/^\s+|\s+$//g;
    return length($text) > $max ? substr($text, 0, $max - 3) . '...' : $text;
}

sub _wrap_guide_fragment {
    my ($self, $title, $body_html, $read_more_url) = @_;
    my $h = '<h2>' . $self->_escape_html($title) . '</h2>' . $body_html;
    if ($read_more_url) {
        $h .= '<p><a href="' . $self->_escape_html($read_more_url) . '">Read full guide</a></p>';
    }
    return $h;
}

sub _escape_html {
    my ($self, $text) = @_;
    $text //= '';
    $text =~ s/&/&amp;/g;
    $text =~ s/</&lt;/g;
    $text =~ s/>/&gt;/g;
    $text =~ s/"/&quot;/g;
    return $text;
}

sub _decode_basic_entities {
    my ($self, $text) = @_;
    $text //= '';
    $text =~ s/&amp;/&/g;
    $text =~ s/&lt;/</g;
    $text =~ s/&gt;/>/g;
    $text =~ s/&quot;/"/g;
    $text =~ s/&#39;/'/g;
    return $text;
}

sub _count_href_links {
    my ($self, $html) = @_;
    return 0 unless $html;
    my $n = () = $html =~ /href\s*=\s*["'][^"']+["']/gi;
    return $n;
}

sub _date_only {
    my ($self, $dt) = @_;
    return '' unless defined $dt && $dt ne '';
    my $s = "$dt";
    $s =~ s/T.*$//;
    $s =~ s/ .*$//;
    return $s;
}

sub _build_feature_guide_context_lines {
    my ($self, $guides) = @_;
    return () unless $guides && @$guides;

    my @out = (
        "FEATURE GUIDES — CURATED MEMBER HOW-TO (PRIMARY SOURCE; use these verbatim where possible):",
        "  These were written when features shipped. Copy links and steps; do not invent alternatives.",
    );
    for my $g (@$guides) {
        push @out, "GUIDE: " . ($g->{title} // '');
        push @out, "  ID: " . ($g->{id} // '');
        push @out, "  URL: " . ($g->{url} // '');
        push @out, "  EXCERPT: " . ($g->{excerpt} // '');
        push @out, "  BODY HTML:";
        push @out, $g->{html_fragment} // '';
        push @out, "";
    }
    return @out;
}

sub _build_feature_guide_html {
    my ($self, $c, $sitename, $guide_ids) = @_;
    my %by_id = map { $_->{id} => $_ } $self->_list_available_feature_guides($c, $sitename);
    my @guides = grep { $_ } map { $by_id{$_} } @$guide_ids;
    my $html = join "\n\n", map { $_->{html_fragment} // '' } @guides;
    return ($html, scalar @guides);
}

# ─── helpers ────────────────────────────────────────────────────────────────

sub _do_send {
    my ($self, $c, $page, $list, $site_id) = @_;

    my $subject = $c->req->param('subject') // $page->title;
    my $teaser  = $c->req->param('teaser')  // '';
    my $list_id = $c->req->param('mailing_list_id') // ($list ? $list->id : undef);

    unless ($subject && $teaser) {
        $c->flash->{error_msg} = 'Subject and email teaser are required.';
        $c->res->redirect($c->uri_for('/mail/newsletter/send', $page->id));
        return;
    }

    unless ($list_id) {
        $c->flash->{error_msg} = 'No mailing list configured for this site.';
        $c->res->redirect($c->uri_for('/mail/newsletter/send', $page->id));
        return;
    }

    my @recipients = $self->_get_list_recipients_with_tokens($c, $list_id);
    unless (@recipients) {
        $c->flash->{error_msg} = 'No active subscribers on the selected list.';
        $c->res->redirect($c->uri_for('/mail/newsletter/send', $page->id));
        return;
    }

    my $read_url = $self->_absolute_uri($c, $c->uri_for('/page', $page->page_code));
    my $campaign;
    eval {
        $campaign = $c->model('DBEncy')->resultset('MailingListCampaign')->create({
            mailing_list_id => $list_id,
            page_id         => $page->id,
            subject         => $subject,
            email_teaser    => $teaser,
            body_html       => $teaser,
            status          => 'sending',
            sent_by         => $c->session->{user_id} || 0,
            recipient_count => scalar(@recipients),
        });
    };

    my ($sent, $failed) = (0, 0);
    for my $r (@recipients) {
        my $body = $self->_build_email_body($c, $teaser, $read_url, $r, $page);
        my $sub  = $subject;
        for my $tag (qw/FIRST_NAME LAST_NAME EMAIL USERNAME/) {
            my $val = $r->{lc $tag} // '';
            $sub  =~ s/\[$tag\]/$val/g;
        }
        my $ok = eval {
            $c->model('Mail')->send_email($c, $r->{email}, $sub, $body, $site_id, { html => 1 });
        };
        if ($@ || !$ok) {
            $failed++;
        } else {
            $sent++;
        }
    }

    eval {
        $page->update({ status => 'active' }) if $page->status eq 'draft';
    };
    eval {
        $campaign->update({
            status          => ($failed && !$sent) ? 'failed' : 'sent',
            success_count   => $sent,
            fail_count      => $failed,
            recipient_count => scalar(@recipients),
        }) if $campaign;
    };

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_do_send',
        "Newsletter sent page_id=" . $page->id . " sent=$sent failed=$failed");

    if ($sent && !$failed) {
        $c->flash->{success_msg} = "Newsletter sent to $sent subscriber(s). Published at $read_url";
    } elsif ($sent) {
        $c->flash->{success_msg} = "$sent sent, $failed failed — check application log.";
    } else {
        $c->flash->{error_msg} = "All sends failed. Check SMTP configuration.";
    }
    $c->res->redirect($c->uri_for('/mail/newsletters'));
}

sub _build_email_body {
    my ($self, $c, $teaser, $read_url, $recipient, $page) = @_;

    my $body = $teaser;
    for my $tag (qw/first_name last_name email username/) {
        my $macro = uc $tag;
        my $val   = $recipient->{$tag} // '';
        $body =~ s/\[$macro\]/$val/g;
    }

    my $unsub = '';
    if ($recipient->{unsubscribe_token}) {
        my $unsub_url = $self->_absolute_uri($c,
            $c->uri_for('/mail/unsubscribe', $recipient->{unsubscribe_token}));
        $unsub = qq{<p style="font-size:0.85em;color:#666;margin-top:24px;">
            <a href="$unsub_url">Unsubscribe</a> from this mailing list.</p>};
    }

    return qq{
<div style="font-family:sans-serif;max-width:600px;margin:0 auto;">
  $body
  <p style="margin:24px 0;">
    <a href="$read_url" style="display:inline-block;background:#1565c0;color:#fff;
       padding:12px 24px;text-decoration:none;border-radius:4px;font-weight:bold;">
      Read full newsletter online
    </a>
  </p>
  <p style="font-size:0.9em;color:#555;">Or copy this link: <a href="$read_url">$read_url</a></p>
  $unsub
</div>};
}

sub _get_list_recipients_with_tokens {
    my ($self, $c, $list_id) = @_;
    my @recipients;
    eval {
        my $rs = $c->model('DBEncy')->resultset('MailingListSubscription')->search(
            { mailing_list_id => $list_id, is_active => 1 },
            { prefetch => 'user' },
        );
        while (my $sub = $rs->next) {
            next if ($sub->status // 'subscribed') eq 'blocked';
            next if ($sub->status // '') eq 'unsubscribed';
            my $email = $sub->user ? $sub->user->email : $sub->email;
            next unless $email && $email =~ /\@/;
            push @recipients, {
                email              => $email,
                first_name         => ($sub->user ? $sub->user->first_name : $sub->first_name) // '',
                last_name          => ($sub->user ? $sub->user->last_name  : $sub->last_name)  // '',
                username           => ($sub->user ? $sub->user->username   : '') // '',
                unsubscribe_token  => $sub->unsubscribe_token // '',
            };
        }
    };
    return @recipients;
}

sub _fetch_archive_sections {
    my ($self, $c, $sitename, $user_roles, $is_admin) = @_;

    my (@own_public, @own_private, %shared);

    my @pages;
    eval {
        @pages = $c->model('DBEncy')->resultset('Page')->search(
            {
                -and => [
                    $self->_newsletter_search_cond($sitename, include_drafts => 0),
                    {
                        -or => [
                            { sitename => $sitename },
                            { share_with => 'all' },
                            { share_with => { 'like' => "%$sitename%" } },
                        ],
                    },
                ],
            },
            { order_by => { -desc => 'updated_at' } },
        )->all;
    };

    for my $p (@pages) {
        next unless $self->_page_visible_in_archive($c, $p, $sitename, $user_roles, $is_admin);
        my $row = $self->_page_to_hash($p);
        if ($p->sitename eq $sitename) {
            if (($p->roles // 'public') eq 'public') {
                push @own_public, $row;
            } else {
                push @own_private, $row;
            }
        } else {
            push @{ $shared{ $p->sitename } }, $row;
        }
    }

    my @all_own = (@own_public, @own_private);
    my $series_groups = $self->_build_archive_series_groups($c, $sitename, \@all_own);

    return (\@own_public, \@own_private, \%shared, $series_groups);
}

sub _page_visible_in_archive {
    my ($self, $c, $page, $sitename, $user_roles, $is_admin) = @_;

    return 0 if $page->status eq 'draft' && !$is_admin;
    return 0 if $page->status eq 'inactive';

    if ($page->sitename ne $sitename) {
        my $sw = $page->share_with // '';
        return 0 unless $sw eq 'all' || $sw =~ /\Q$sitename\E/;
    }

    return 1;
}

sub _issue_search_cond {
    my ($self, %opts) = @_;
    my $include_drafts = $opts{include_drafts};
    my @status = $include_drafts ? () : (status => { -in => [qw/active published/] });
    return {
        page_type => 'newsletter',
        ($include_drafts ? () : @status),
    };
}

sub _publication_search_cond {
    my ($self, %opts) = @_;
    my $include_drafts = $opts{include_drafts};
    my @status = $include_drafts ? () : (status => { -in => [qw/active published/] });
    return {
        page_type => 'newsletter_pub',
        ($include_drafts ? () : @status),
    };
}

sub _newsletter_search_cond { shift->_issue_search_cond(@_) }

sub _is_newsletter_publication {
    my ($self, $page) = @_;
    return (($page->page_type // '') eq 'newsletter_pub');
}

sub _is_newsletter_issue {
    my ($self, $page) = @_;
    return 0 if $self->_is_newsletter_publication($page);
    return (($page->page_type // '') eq 'newsletter')
        || (($page->menu // '') eq 'newsletter');
}

sub _is_newsletter_page { shift->_is_newsletter_issue(@_) }

sub _find_newsletter_page {
    my ($self, $c, $page_code, $sitename, %opts) = @_;
    my $page = $c->model('DBEncy')->resultset('Page')->search(
        { sitename => $sitename, page_code => $page_code },
        { rows => 1 },
    )->single;
    if (!$page && $sitename eq 'CSC') {
        $page = $c->model('DBEncy')->resultset('Page')->search(
            { page_code => $page_code },
            { rows => 1 },
        )->single;
    }
    return unless $page && $self->_is_newsletter_issue($page);
    return $page;
}

sub _find_newsletter_publication {
    my ($self, $c, $page_code, $sitename) = @_;
    my $page = $c->model('DBEncy')->resultset('Page')->search(
        { page_code => $page_code, page_type => 'newsletter_pub' },
        { rows => 1 },
    )->single;
    return unless $page && $self->_is_newsletter_publication($page);
    return $page if $self->_can_admin_publication($c, $page, $sitename);
    return;
}

sub _infer_newsletter_meta_from_page_code {
    my ($self, $page_code, $title) = @_;
    my $cat = $self->_newsletter_series_catalog();
    my ($series, $version) = ('hosting', 1);
    $title //= '';
    for my $key (keys %$cat) {
        my $prefix = $cat->{$key}{slug_prefix};
        if ($page_code =~ /^\Q$prefix\E-v(\d+)/i) {
            $series = $key;
            $version = $1;
            last;
        }
    }
    my $blob = lc("$page_code $title");
    if ($blob =~ /hosting/)              { $series = 'hosting'; }
    elsif ($blob =~ /dns/)               { $series = 'dns'; }
    elsif ($blob =~ /beekeeping|apiary/) { $series = 'beekeeping'; }
    elsif ($blob =~ /newsletter|news.letter/) { $series = 'hosting'; }
    if ($page_code =~ /-v(\d+)-/i) { $version = $1; }
    elsif ($page_code =~ /-v(\d+)$/i) { $version = $1; }
    return { nl_series => $series, nl_version => $version };
}

sub _page_to_hash {
    my ($self, $p) = @_;
    my $meta = $self->_parse_newsletter_meta($p->keywords, $p->page_code, $p->title);
    return {
        id            => $p->id,
        page_code     => $p->page_code,
        title         => $p->title,
        description   => $p->description // '',
        sitename      => $p->sitename,
        status        => $p->status,
        roles         => $p->roles // 'public',
        share_with    => $p->share_with // '',
        updated_at    => $p->updated_at,
        is_public     => (($p->roles // 'public') eq 'public') ? 1 : 0,
        nl_series     => $meta->{series},
        nl_series_label => $meta->{series_label},
        nl_version    => $meta->{version},
        nl_audience   => $meta->{audience_label},
        nl_mailing_list => $meta->{mailing_list},
        nl_pub_id       => $meta->{pub_id},
        nl_pub_code     => $meta->{pub_code},
        nl_pub_title    => $meta->{pub_title} // '',
        display_label   => $self->_newsletter_issue_display_label($meta, $p->title),
    };
}

sub _ensure_newsletter_list {
    my ($self, $c, $site_id) = @_;
    return unless $site_id;
    my $list;
    eval {
        my $rs = $c->model('DBEncy')->resultset('MailingList');
        $list = $rs->find({ site_id => $site_id, name => 'Newsletter' });
        unless ($list) {
            $list = $rs->create({
                site_id          => $site_id,
                name             => 'Newsletter',
                description      => 'Site newsletter — public updates and announcements',
                is_software_only => 1,
                is_active        => 1,
                is_public        => 1,
                list_backend     => 'local',
                created_by       => $c->session->{user_id} || 0,
            });
        } else {
            $list->update({ is_active => 1, is_public => 1 });
        }
    };
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_ensure_newsletter_list',
        "List setup error: $@") if $@;
    return $list;
}

sub _fetch_site_mailing_lists {
    my ($self, $c, $site_id) = @_;
    return () unless $site_id;
    my @out;
    eval {
        my $rs = $c->model('DBEncy')->resultset('MailingList')->search(
            { site_id => $site_id, is_active => 1 },
            { order_by => { -asc => 'name' } },
        );
        while (my $ml = $rs->next) {
            my $cnt = $c->model('DBEncy')->resultset('MailingListSubscription')->search(
                { mailing_list_id => $ml->id, is_active => 1 },
            )->count;
            my $desc = $ml->description // '';
            push @out, {
                id          => $ml->id,
                name        => $ml->name,
                description => $desc,
                is_default  => ($desc =~ /^\[auto\]/) ? 1 : 0,
                is_public   => ($ml->is_public // 0) ? 1 : 0,
                sub_count   => $cnt,
            };
        }
    };
    @out = sort {
        my $ad = $a->{is_default} ? 0 : 1;
        my $bd = $b->{is_default} ? 0 : 1;
        $ad <=> $bd
            || lc($a->{name}) cmp lc($b->{name});
    } @out;
    return @out;
}

sub _default_mailing_list_id {
    my ($self, $lists) = @_;
    return undef unless $lists && @$lists;
    for my $l (@$lists) {
        return $l->{id} if ($l->{name} // '') =~ /^Hosting Customers$/i;
    }
    for my $l (@$lists) {
        return $l->{id} if ($l->{name} // '') =~ /^Newsletter$/i;
    }
    for my $l (@$lists) {
        return $l->{id} if ($l->{sub_count} // 0) > 0;
    }
    return $lists->[0]{id};
}

sub _default_teaser {
    my ($self, $page) = @_;
    my $body = $page->body        // '';
    my $desc = $page->description // '';

    my $excerpt = '';
    if ($desc =~ /\S/) {
        $excerpt = $self->_escape_html($desc);
    } elsif ($body =~ /<p[^>]*>(.*?)<\/p>/is) {
        my $p = $1;
        $p =~ s/<[^>]+>//g;
        $p =~ s/\s+/ /g;
        $p =~ s/^\s+|\s+$//g;
        $excerpt = $self->_escape_html($p);
    } else {
        my $text = $body;
        $text =~ s/<[^>]+>//g;
        $text =~ s/\s+/ /g;
        $text =~ s/^\s+|\s+$//g;
        $text = substr($text, 0, 380) . '...' if length($text) > 380;
        $excerpt = $self->_escape_html($text);
    }

    return '<p>Valued Member: [FIRST_NAME] [LAST_NAME],</p>'
         . ($excerpt ? "<p>$excerpt</p>" : '<p>We have published a new newsletter for our hosting customers.</p>');
}

# ─── Newsletter publications (containers) and admin tree ────────────────────

sub _available_sites_for_admin {
    my ($self, $c, $sitename) = @_;
    if ($sitename eq 'CSC') {
        my $sites = eval { $c->model('Site')->get_all_sites($c) };
        return $sites ? map { $_->name } @$sites : ($sitename);
    }
    return ($sitename);
}

sub _can_admin_sitename {
    my ($self, $c, $target_site) = @_;
    my $sitename = $self->_get_sitename($c);
    return 1 if $sitename eq 'CSC';
    return $target_site eq $sitename;
}

sub _can_admin_publication {
    my ($self, $c, $pub, $sitename) = @_;
    return 0 unless $pub;
    return 1 if $sitename eq 'CSC';
    return 1 if $pub->sitename eq $sitename;
    return 0;
}

sub _find_publication_by_id {
    my ($self, $c, $pub_id, $sitename) = @_;
    my $pub = eval { $c->model('DBEncy')->resultset('Page')->find($pub_id) };
    return unless $pub && $self->_is_newsletter_publication($pub);
    return $pub if $self->_can_admin_publication($c, $pub, $sitename);
    return;
}

sub _parse_publication_meta {
    my ($self, $keywords, $title) = @_;
    my %meta;
    if ($keywords && $keywords =~ /^\s*\{/) {
        eval { %meta = %{ decode_json($keywords) } };
    }
    my $series = $meta{nl_series} // 'hosting';
    my $cat = $self->_newsletter_series_catalog();
    my $def = $cat->{$series} // $cat->{hosting};
    return {
        series          => $series,
        audience_label  => $meta{nl_audience} // $def->{audience_label},
        mailing_list    => $meta{nl_mailing_list} // $def->{mailing_list},
        mailing_list_id => ($meta{nl_mailing_list_id} && $meta{nl_mailing_list_id} =~ /^\d+$/)
            ? int($meta{nl_mailing_list_id}) : undef,
        visible_to      => $meta{nl_visible_to} // 'hosting_members',
        custom_label    => $meta{nl_custom_label} // '',
    };
}

sub _encode_publication_meta {
    my ($self, $meta) = @_;
    my %out = (
        nl_series       => $meta->{series},
        nl_audience     => $meta->{audience_label},
        nl_mailing_list => $meta->{mailing_list},
        nl_visible_to   => $meta->{visible_to},
        nl_custom_label => $meta->{custom_label} // '',
    );
    $out{nl_mailing_list_id} = int($meta->{mailing_list_id})
        if $meta->{mailing_list_id} && $meta->{mailing_list_id} =~ /^\d+$/;
    return encode_json(\%out);
}

sub _build_publication_meta_from_form {
    my ($self, $series, $custom_label, $visible_to) = @_;
    $custom_label =~ s/^\s+|\s+$//g if defined $custom_label;
    $series = 'custom' if $series eq 'custom' && $custom_label;
    my $cat = $self->_newsletter_series_catalog();
    if ($series eq 'custom') {
        return {
            series         => 'custom',
            audience_label => "For $custom_label readers",
            mailing_list   => 'Newsletter',
            visible_to     => $visible_to // 'own_site',
            custom_label   => $custom_label,
        };
    }
    my $def = $cat->{$series} // $cat->{hosting};
    return {
        series         => $series,
        audience_label => $def->{audience_label},
        mailing_list   => $def->{mailing_list},
        visible_to     => $visible_to // 'hosting_members',
        custom_label   => '',
    };
}

sub _build_publication_page_code {
    my ($self, $meta, $title) = @_;
    my $cat = $self->_newsletter_series_catalog();
    my $base = $meta->{series} eq 'custom'
        ? $self->_slug_base($meta->{custom_label} || $title)
        : ($cat->{ $meta->{series} }{slug_prefix} // 'site-news');
    $base =~ s/-news$//;
    return 'nl-pub-' . $base;
}

sub _publication_to_hash {
    my ($self, $p) = @_;
    my $meta = $self->_parse_publication_meta($p->keywords, $p->title);
    return {
        id            => $p->id,
        page_code     => $p->page_code,
        title         => $p->title,
        description   => $p->description // '',
        sitename      => $p->sitename,
        status        => $p->status,
        share_with    => $p->share_with // '',
        updated_at    => $p->updated_at,
        nl_series          => $meta->{series},
        nl_audience        => $meta->{audience_label},
        nl_mailing_list    => $meta->{mailing_list},
        nl_mailing_list_id => $meta->{mailing_list_id},
        nl_visible_to      => $meta->{visible_to},
        issue_count        => 0,
        issues             => [],
    };
}

sub _publication_visible_to_admin {
    my ($self, $c, $pub, $viewer_sitename) = @_;
    return 0 if $pub->status eq 'inactive';
    return 1 if $viewer_sitename eq 'CSC';
    return 1 if $pub->sitename eq $viewer_sitename;
    return $self->_publication_visible_to_viewer($c, $pub, $viewer_sitename, 1);
}

sub _fetch_admin_publication_rows {
    my ($self, $c, $sitename) = @_;
    my %by_series;
    eval {
        my $rs = $c->model('DBEncy')->resultset('Page')->search(
            {
                page_type => 'newsletter_pub',
                status    => { -in => [qw/active published/] },
            },
            { order_by => [qw/sitename title/] },
        );
        while (my $p = $rs->next) {
            next unless $self->_publication_visible_to_admin($c, $p, $sitename);
            my $pm    = $self->_parse_publication_meta($p->keywords, $p->title);
            my $key   = $pm->{series} // $p->page_code;
            my $row   = $self->_publication_to_hash($p);
            $row->{is_shared}   = ($p->sitename ne $sitename) ? 1 : 0;
            $row->{host_sitename} = $p->sitename;
            if (!$by_series{$key}
                || $p->sitename eq 'CSC'
                || ($by_series{$key}{host_sitename} ne 'CSC' && $p->sitename eq $sitename)) {
                $by_series{$key} = $row;
            }
        }
    };
    return [ sort { lc($a->{title}) cmp lc($b->{title}) } values %by_series ];
}

sub _fetch_publications_for_admin {
    my ($self, $c, $sitename) = @_;
    my $rows = $self->_fetch_admin_publication_rows($c, $sitename);
    return @$rows;
}

sub _fetch_published_issues_for_publication {
    my ($self, $c, $pub_id) = @_;
    my @issues;
    return @issues unless $pub_id;
    eval {
        my $rs = $c->model('DBEncy')->resultset('Page')->search(
            {
                page_type => 'newsletter',
                status    => { -in => [qw/active published/] },
                -or       => [
                    { keywords => { -like => '%"nl_pub_id":' . $pub_id . '%' } },
                    { keywords => { -like => '%"nl_pub_id": ' . $pub_id . '%' } },
                ],
            },
            { order_by => { -desc => 'updated_at' } },
        );
        while (my $p = $rs->next) {
            push @issues, $self->_page_to_hash($p);
        }
    };
    return @issues;
}

sub _build_admin_newsletter_tree {
    my ($self, $c, $sitename, $is_csc) = @_;
    $is_csc //= ($sitename eq 'CSC') ? 1 : 0;
    my @pubs = @{ $self->_fetch_admin_publication_rows($c, $sitename) };
    my @tree;

    for my $pub (@pubs) {
        my @pub_issues = $self->_fetch_published_issues_for_publication($c, $pub->{id});
        @pub_issues = sort { ($b->{nl_version} // 0) <=> ($a->{nl_version} // 0) } @pub_issues;
        for my $issue (@pub_issues) {
            $issue->{can_manage} = ($is_csc || $issue->{sitename} eq $sitename) ? 1 : 0;
        }
        $pub->{can_manage}   = ($is_csc || $pub->{host_sitename} eq $sitename) ? 1 : 0;
        $pub->{issues}       = \@pub_issues;
        $pub->{issue_count}  = scalar @pub_issues;
        push @tree, $pub;
    }

    return \@tree;
}

sub _find_canonical_publication_for_series {
    my ($self, $c, $series) = @_;
    my $pub;
    eval {
        $pub = $c->model('DBEncy')->resultset('Page')->search(
            {
                page_type => 'newsletter_pub',
                sitename  => 'CSC',
                status    => { -in => [qw/active published/] },
                keywords  => { -like => '%"nl_series":"' . $series . '"%' },
            },
            { rows => 1 },
        )->single;
        $pub ||= $c->model('DBEncy')->resultset('Page')->search(
            {
                page_type => 'newsletter_pub',
                status    => { -in => [qw/active published/] },
                keywords  => { -like => '%"nl_series":"' . $series . '"%' },
            },
            { order_by => 'sitename', rows => 1 },
        )->single;
    };
    return $pub;
}

sub _link_orphan_issues_to_publications {
    my ($self, $c) = @_;
    eval {
        my $rs = $c->model('DBEncy')->resultset('Page')->search(
            { page_type => 'newsletter' },
        );
        while (my $issue = $rs->next) {
            my $im = $self->_parse_newsletter_meta($issue->keywords, $issue->page_code, $issue->title);
            next if $im->{pub_id};
            my $series = $im->{series} // 'hosting';
            my $pub    = $self->_find_canonical_publication_for_series($c, $series);
            next unless $pub;
            my $pm = $self->_parse_publication_meta($pub->keywords, $pub->title);
            my $meta = {
                series         => $im->{series},
                series_label   => $pub->title,
                slug_prefix    => $im->{slug_prefix},
                version        => $im->{version},
                audience_label => $pm->{audience_label},
                mailing_list   => $pm->{mailing_list},
                custom_label   => $im->{custom_label} // '',
                pub_id         => $pub->id,
                pub_code       => $pub->page_code,
                pub_title      => $pub->title,
            };
            $issue->update({ keywords => $self->_encode_newsletter_meta($meta) });
        }
    };
}

sub _ensure_csc_hosting_news_publication {
    my ($self, $c) = @_;
    my $exists = $c->model('DBEncy')->resultset('Page')->search(
        {
            sitename  => 'CSC',
            page_type => 'newsletter_pub',
            page_code => 'nl-pub-hosting',
        },
        { rows => 1 },
    )->single;
    return if $exists;

    my $cat = $self->_newsletter_series_catalog();
    my $def = $cat->{hosting};
    eval {
        my $meta = {
            series         => 'hosting',
            audience_label => $def->{audience_label},
            mailing_list   => $def->{mailing_list},
            visible_to     => 'hosting_members',
            custom_label   => '',
        };
        $c->model('DBEncy')->resultset('Page')->create({
            sitename    => 'CSC',
            menu        => 'newsletter',
            page_code   => 'nl-pub-hosting',
            page_type   => 'newsletter_pub',
            title       => $def->{label},
            description => 'Product updates and how-to guides for hosting customers. '
                         . 'Shared with all SiteNames - each site presents this as their hosted newsletter.',
            body        => '<p>' . $self->_escape_html($def->{audience_label}) . '</p>',
            keywords    => $self->_encode_publication_meta($meta),
            status      => 'active',
            roles       => 'public',
            share_with  => 'all',
            link_order  => 0,
            created_by  => 'system',
        });
    };
}

sub _retire_duplicate_publications {
    my ($self, $c) = @_;
    eval {
        my %keeper;
        my $rs = $c->model('DBEncy')->resultset('Page')->search(
            { page_type => 'newsletter_pub', status => { -in => [qw/active published/] } },
        );
        while (my $p = $rs->next) {
            my $pm  = $self->_parse_publication_meta($p->keywords, $p->title);
            my $key = $pm->{series} // $p->page_code;
            if (!$keeper{$key} || $p->sitename eq 'CSC') {
                $keeper{$key} = $p->id;
            }
        }
        my %keep_ids = map { $_ => 1 } values %keeper;
        $rs = $c->model('DBEncy')->resultset('Page')->search(
            { page_type => 'newsletter_pub', status => { -in => [qw/active published/] } },
        );
        while (my $p = $rs->next) {
            next if $keep_ids{ $p->id };
            $p->update({ status => 'inactive' });
        }
    };
}

# DNS News was auto-created per SiteName during early rollout — not a real newsletter yet.
sub _retire_auto_dns_publications {
    my ($self, $c) = @_;
    eval {
        my $rs = $c->model('DBEncy')->resultset('Page')->search(
            {
                page_type => 'newsletter_pub',
                status    => { -in => [qw/active published/] },
                -or       => [
                    { page_code => 'nl-pub-dns' },
                    { keywords  => { -like => '%"nl_series":"dns"%' } },
                ],
            },
        );
        while (my $p = $rs->next) {
            $p->update({ status => 'inactive' });
        }
    };
}

sub _hosting_member_sitenames {
    my ($self, $c) = @_;
    my %sites;
    eval {
        my @accounts = $c->model('DBEncy')->resultset('Accounting::HostingAccount')->search(
            { status => 'active' },
        )->all;
        for my $a (@accounts) {
            for my $sn (grep { defined $_ && $_ ne '' } ($a->sitename, $a->referring_sitename)) {
                $sites{$sn}++;
            }
        }
    };
    $sites{CSC} = 1;
    return \%sites;
}

sub _is_hosting_member_sitename {
    my ($self, $c, $sitename) = @_;
    my $map = $self->_hosting_member_sitenames($c);
    return $map->{ $sitename } ? 1 : 0;
}

sub _publication_visible_to_viewer {
    my ($self, $c, $pub, $viewer_sitename, $is_admin) = @_;
    return 0 if $pub->status eq 'inactive';
    return 0 if $pub->status eq 'draft' && !$is_admin;

    return 1 if $pub->sitename eq $viewer_sitename;

    my $meta = $self->_parse_publication_meta($pub->keywords, $pub->title);
    if (($meta->{visible_to} // '') eq 'hosting_members') {
        return 1;
    }

    my $sw = $pub->share_with // '';
    return 1 if $sw eq 'all';
    return 1 if $sw =~ /\Q$viewer_sitename\E/;
    return 0;
}

sub _issue_visible_in_archive {
    my ($self, $c, $issue, $sitename, $user_roles, $is_admin) = @_;
    return 0 unless $self->_is_newsletter_issue($issue);
    return 0 if $issue->status eq 'draft' && !$is_admin;
    return 0 if $issue->status eq 'inactive';
    return 1 if $issue->sitename eq $sitename;
    my $sw = $issue->share_with // '';
    return 1 if $sw eq 'all' || $sw =~ /\Q$sitename\E/;
    return 0;
}

sub _fetch_archive_publications {
    my ($self, $c, $sitename, $user_roles, $is_admin) = @_;
    my @tree;

    for my $pub (@{ $self->_fetch_admin_publication_rows($c, $sitename) }) {
        my @issues = grep {
            $self->_issue_row_visible_in_archive($_, $sitename, $user_roles, $is_admin)
        } $self->_fetch_published_issues_for_publication($c, $pub->{id});

        next unless @issues;
        @issues = sort { ($b->{nl_version} // 0) <=> ($a->{nl_version} // 0) } @issues;
        $pub->{issues}      = \@issues;
        $pub->{issue_count} = scalar @issues;

        my $list_id = $self->_resolve_mailing_list_id($c, $pub->{host_sitename} // $pub->{sitename},
            $pub->{nl_mailing_list}, $pub->{nl_mailing_list_id});
        $pub->{subscribe_url} = $list_id
            ? $c->uri_for('/mail/subscribe', { highlight => $list_id })
            : $c->uri_for('/mail/subscribe');

        push @tree, $pub;
    }

    return (\@tree, {});
}

sub _issue_row_visible_in_archive {
    my ($self, $issue, $sitename, $user_roles, $is_admin) = @_;
    return 0 if ($issue->{status} // '') eq 'inactive';
    return 1 if $is_admin;
    return 1 if $issue->{is_public};
    my $roles = ref $user_roles ? join(',', @$user_roles) : ($user_roles // 'public');
    my $need  = $issue->{roles} // 'member';
    return 1 if $roles =~ /\badmin\b/i;
    return 1 if $need eq 'member' && $roles !~ /\bpublic\b/i;
    return 0;
}

# ─── Newsletter series, version, and URL naming ─────────────────────────────

sub _newsletter_series_catalog {
    return {
        hosting => {
            label            => 'Hosting News',
            audience_label   => 'For hosting customers',
            slug_prefix      => 'hosting-news',
            mailing_list     => 'Hosting Customers',
            default_audience => 'hosting_customers',
        },
        dns => {
            label            => 'DNS News',
            audience_label   => 'For customers using our DNS services',
            slug_prefix      => 'dns-news',
            mailing_list     => 'Hosting Customers',
            default_audience => 'dns_customers',
        },
        beekeeping => {
            label            => 'Beekeeping News',
            audience_label   => 'For beekeepers and apiary members',
            slug_prefix      => 'beekeeping-news',
            mailing_list     => 'Newsletter',
            default_audience => 'beekeepers',
        },
        site => {
            label            => 'Site News',
            audience_label   => 'General updates for site members',
            slug_prefix      => 'site-news',
            mailing_list     => 'Newsletter',
            default_audience => 'members',
        },
    };
}

sub _newsletter_series_list {
    my ($self) = @_;
    my $cat = $self->_newsletter_series_catalog();
    return map {
        +{
            key          => $_,
            label        => $cat->{$_}{label},
            audience     => $cat->{$_}{audience_label},
            slug_prefix  => $cat->{$_}{slug_prefix},
            mailing_list => $cat->{$_}{mailing_list},
        }
    } sort keys %$cat;
}

sub _parse_newsletter_meta {
    my ($self, $keywords, $page_code, $title) = @_;
    my %meta;
    if ($keywords && $keywords =~ /^\s*\{/ && $keywords =~ /nl_series/) {
        eval { %meta = %{ decode_json($keywords) } };
    } elsif ($page_code) {
        %meta = %{ $self->_infer_newsletter_meta_from_page_code($page_code, $title) };
    }
    my $cat = $self->_newsletter_series_catalog();
    my $series = $meta{nl_series} // 'site';
    if ($series eq 'custom' && $meta{nl_custom_label}) {
        my $slug = $self->_slug_base($meta{nl_custom_label});
        return {
            series         => 'custom',
            series_label   => $meta{nl_custom_label},
            slug_prefix    => "$slug-news",
            version        => $meta{nl_version} // 1,
            audience_label => $meta{nl_audience} // 'For subscribers',
            mailing_list   => $meta{nl_mailing_list} // 'Newsletter',
            custom_label   => $meta{nl_custom_label},
        };
    }
    my $def = $cat->{$series} // $cat->{site};
    return {
        series         => $series,
        series_label   => $def->{label},
        slug_prefix    => $def->{slug_prefix},
        version        => $meta{nl_version} // 1,
        audience_label => $def->{audience_label},
        mailing_list   => $def->{mailing_list},
        custom_label   => '',
        pub_id         => $meta{nl_pub_id},
        pub_code       => $meta{nl_pub_code},
        pub_title      => $meta{nl_pub_title},
    };
}

sub _encode_newsletter_meta {
    my ($self, $meta) = @_;
    return encode_json({
        nl_series       => $meta->{series},
        nl_version      => $meta->{version},
        nl_custom_label => $meta->{custom_label} // '',
        nl_audience     => $meta->{audience_label},
        nl_mailing_list => $meta->{mailing_list},
        nl_pub_id       => $meta->{pub_id},
        nl_pub_code     => $meta->{pub_code},
        nl_pub_title    => $meta->{pub_title} // '',
    });
}

sub _build_newsletter_meta_from_form {
    my ($self, $c, $sitename, $series, $version, $custom_label, $publication) = @_;
    $series = 'hosting' unless defined $series && $series =~ /\S/;
    $custom_label =~ s/^\s+|\s+$//g if defined $custom_label;
    $series = 'custom' if $series eq 'custom' && $custom_label;

    my $cat = $self->_newsletter_series_catalog();
    my %meta;
    my $version_key = $series;
    if ($series eq 'custom') {
        my $slug = $self->_slug_base($custom_label || 'custom');
        $version_key = "custom:$slug";
        %meta = (
            series         => 'custom',
            series_label   => $custom_label || 'Custom News',
            slug_prefix    => "$slug-news",
            version        => 0,
            audience_label => 'For subscribers',
            mailing_list   => 'Newsletter',
            custom_label   => $custom_label,
        );
    } else {
        my $def = $cat->{$series} // $cat->{hosting};
        %meta = (
            series         => $series,
            series_label   => $def->{label},
            slug_prefix    => $def->{slug_prefix},
            version        => 0,
            audience_label => $def->{audience_label},
            mailing_list   => $def->{mailing_list},
            custom_label   => '',
        );
    }
    if ($publication) {
        my $pm = $self->_parse_publication_meta($publication->keywords, $publication->title);
        $meta{series_label}   = $publication->title;
        $meta{audience_label} = $pm->{audience_label};
        $meta{mailing_list}   = $pm->{mailing_list};
        $meta{pub_id}         = $publication->id;
        $meta{pub_code}       = $publication->page_code;
        $meta{pub_title}      = $publication->title;
        $version_key          = 'pub:' . $publication->id;
    }
    $meta{version} = $self->_coerce_version($version, $c, $sitename, $version_key);
    return \%meta;
}

sub _coerce_version {
    my ($self, $version, $c, $sitename, $series_key) = @_;
    return int($version) if defined $version && $version =~ /^\d+$/ && $version > 0;
    return $self->_next_newsletter_version($c, $sitename, $series_key);
}

sub _next_newsletter_version {
    my ($self, $c, $sitename, $series_key) = @_;
    my $max = 0;
    eval {
        my $rs = $c->model('DBEncy')->resultset('Page')->search(
            {
                sitename  => $sitename,
                page_type => 'newsletter',
            },
        );
        while (my $p = $rs->next) {
            my $m = $self->_parse_newsletter_meta($p->keywords, $p->page_code, $p->title);
            my $key;
            if ($series_key =~ /^pub:(\d+)$/) {
                $key = 'pub:' . ($m->{pub_id} // 0);
            } else {
                $key = $m->{series} eq 'custom'
                    ? 'custom:' . $self->_slug_base($m->{custom_label} // 'custom')
                    : $m->{series};
            }
            next unless $key eq $series_key;
            $max = $m->{version} if ($m->{version} // 0) > $max;
        }
    };
    return $max + 1;
}

sub _build_newsletter_page_code {
    my ($self, $meta) = @_;
    my $ym = strftime('%Y-%m', localtime);
    return sprintf('%s-v%d-%s', $meta->{slug_prefix}, $meta->{version}, $ym);
}

sub _build_newsletter_title {
    my ($self, $meta) = @_;
    my $month_year = strftime('%B %Y', localtime);
    return sprintf('%s — %s (Issue %d)', $meta->{series_label}, $month_year, $meta->{version});
}

sub _build_newsletter_description {
    my ($self, $meta) = @_;
    my $month_year = strftime('%B %Y', localtime);
    return sprintf('%s — %s, issue %d.', $meta->{audience_label}, $month_year, $meta->{version});
}

sub _newsletter_issue_display_label {
    my ($self, $meta, $title) = @_;
    if ($title && $title =~ /issue\s*\d+/i) {
        return $title;
    }
    my $month_year = '';
    if ($title && $title =~ /((?:January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{4})/i) {
        $month_year = $1;
    } else {
        $month_year = strftime('%B %Y', localtime);
    }
    return sprintf('%s — %s (Issue %d)', $meta->{series_label}, $month_year, $meta->{version});
}

sub _newsletter_display_label { shift->_newsletter_issue_display_label(@_) }

sub _normalize_newsletter_page_code {
    my ($self, $code) = @_;
    $code = lc($code // '');
    $code =~ s/^\/page\///;
    $code =~ s/[^a-z0-9\-]+/-/g;
    $code =~ s/-{2,}/-/g;
    $code =~ s/^-+|-+$//g;
    return $code;
}

sub _slug_base {
    my ($self, $text) = @_;
    $text = lc($text // '');
    $text =~ s/\b(?:newsletter|news(?:\s*letter)?|letter|the|for|a|an|our|to|of)\b//gi;
    $text =~ s/[^a-z0-9]+/-/g;
    $text =~ s/-{2,}/-/g;
    $text =~ s/^-+|-+$//g;
    $text = 'update' unless $text;
    return $text;
}

sub _build_archive_series_groups {
    my ($self, $c, $sitename, $issues_ref) = @_;
    my %groups;
    for my $issue (@$issues_ref) {
        my $key = $issue->{nl_series} // 'site';
        push @{ $groups{$key} }, $issue;
    }
    my $cat = $self->_newsletter_series_catalog();
    my @out;
    for my $key (sort {
        my $la = $groups{$a}[0]{nl_series_label} // $a;
        my $lb = $groups{$b}[0]{nl_series_label} // $b;
        lc($la) cmp lc($lb);
    } keys %groups) {
        my @issues = sort {
            ($b->{nl_version} // 0) <=> ($a->{nl_version} // 0)
                || ($b->{updated_at} // '') cmp ($a->{updated_at} // '')
        } @{ $groups{$key} };
        my $sample = $issues[0];
        my $def = $cat->{$key} // {};
        my $list_name = $sample->{nl_mailing_list} // $def->{mailing_list} // 'Newsletter';
        my $list_id = $self->_resolve_mailing_list_id($c, $sitename, $list_name);
        push @out, {
            key           => $key,
            label         => $sample->{nl_series_label} // $def->{label} // $key,
            audience      => $sample->{nl_audience} // $def->{audience_label} // '',
            mailing_list  => $list_name,
            subscribe_url => $list_id
                ? $c->uri_for('/mail/subscribe', { highlight => $list_id })
                : $c->uri_for('/mail/subscribe'),
            issues        => \@issues,
        };
    }
    return \@out;
}

sub _resolve_mailing_list_id {
    my ($self, $c, $sitename, $list_name, $list_id) = @_;
    my $info = $self->_lookup_mailing_list($c, $sitename, $list_name, $list_id);
    return $info ? $info->{id} : undef;
}

sub _lookup_mailing_list {
    my ($self, $c, $sitename, $list_name, $list_id) = @_;
    my $site_id = $self->_get_site_id_for_sitename($c, $sitename);
    return unless $site_id;

    my $list;
    eval {
        if ($list_id && $list_id =~ /^\d+$/) {
            $list = $c->model('DBEncy')->resultset('MailingList')->search(
                { id => $list_id, site_id => $site_id, is_active => 1 },
                { rows => 1 },
            )->single;
        }
        elsif ($list_name) {
            $list = $c->model('DBEncy')->resultset('MailingList')->search(
                { site_id => $site_id, name => $list_name, is_active => 1 },
                { rows => 1 },
            )->single;
        }
    };
    return unless $list;
    return {
        id        => $list->id,
        name      => $list->name,
        is_public => ($list->is_public // 0) ? 1 : 0,
        is_active => ($list->is_active // 0) ? 1 : 0,
    };
}

sub _ensure_publication_subscription_list {
    my ($self, $c, $pub_meta, $target_site, $title, $description) = @_;
    my $site_id = $self->_get_site_id_for_sitename($c, $target_site);
    return unless $site_id && $pub_meta;

    if ($pub_meta->{mailing_list_id}) {
        my $by_id = $self->_lookup_mailing_list($c, $target_site, undef, $pub_meta->{mailing_list_id});
        if ($by_id && $by_id->{is_public}) {
            $pub_meta->{mailing_list} = $by_id->{name};
            return $by_id;
        }
    }

    my $by_name = $self->_lookup_mailing_list($c, $target_site, $pub_meta->{mailing_list});
    if ($by_name) {
        unless ($by_name->{is_public}) {
            eval {
                my $row = $c->model('DBEncy')->resultset('MailingList')->find($by_name->{id});
                $row->update({ is_public => 1, is_active => 1 }) if $row;
            };
            $by_name->{is_public} = 1;
        }
        $pub_meta->{mailing_list_id} = $by_name->{id};
        $pub_meta->{mailing_list}    = $by_name->{name};
        return $by_name;
    }

    my $list_name = $title // $pub_meta->{mailing_list} // 'Newsletter';
    $list_name =~ s/^\s+|\s+$//g;
    my $list = $self->_create_public_mailing_list($c, $site_id, $list_name, $description);
    if ($list) {
        $pub_meta->{mailing_list_id} = $list->id;
        $pub_meta->{mailing_list}    = $list->name;
    }
    return $list;
}

sub _apply_publication_mailing_list {
    my ($self, $c, $pub_meta, $target_site, $title, $description, $params) = @_;
    $params ||= {};
    my $site_id = $self->_get_site_id_for_sitename($c, $target_site);
    return unless $site_id && $pub_meta;

    if ($params->{create_list}) {
        my $list_name = $params->{list_name} // $title // $pub_meta->{mailing_list};
        $list_name =~ s/^\s+|\s+$//g;
        my $list = $self->_create_public_mailing_list($c, $site_id, $list_name, $description);
        if ($list) {
            $pub_meta->{mailing_list_id} = $list->id;
            $pub_meta->{mailing_list}    = $list->name;
        }
        return;
    }

    my $list_id = $params->{mailing_list_id};
    return unless $list_id && $list_id =~ /^\d+$/;

    my $list = eval {
        $c->model('DBEncy')->resultset('MailingList')->find({
            id => $list_id, site_id => $site_id, is_active => 1,
        });
    };
    if ($list) {
        $pub_meta->{mailing_list_id} = $list->id;
        $pub_meta->{mailing_list}    = $list->name;
    }
}

sub _create_public_mailing_list {
    my ($self, $c, $site_id, $name, $description) = @_;
    $name =~ s/^\s+|\s+$//g if defined $name;
    $description =~ s/^\s+|\s+$//g if defined $description;
    return unless $site_id && $name;

    my $list;
    eval {
        my $rs = $c->model('DBEncy')->resultset('MailingList');
        $list = $rs->find({ site_id => $site_id, name => $name });
        unless ($list) {
            $list = $rs->create({
                site_id          => $site_id,
                name             => $name,
                description      => $description || '',
                is_software_only => 1,
                is_active        => 1,
                is_public        => 1,
                list_backend     => 'local',
                created_by       => $c->session->{user_id} || 0,
            });
        } else {
            my %upd = ( is_active => 1, is_public => 1 );
            $upd{description} = $description if defined $description && $description =~ /\S/;
            $list->update(\%upd);
        }
    };
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_create_public_mailing_list',
        "List setup error: $@") if $@;
    return $list;
}

sub _mailing_list_link_status {
    my ($self, $c, $sitename, $pub_meta) = @_;
    my $expected_name = $pub_meta->{mailing_list} // 'Newsletter';
    my $info = {
        linked    => 0,
        id        => undef,
        name      => $expected_name,
        is_public => 0,
        is_active => 0,
        message   => '',
    };
    my $list = $self->_lookup_mailing_list(
        $c, $sitename, $pub_meta->{mailing_list}, $pub_meta->{mailing_list_id}
    );
    if ($list) {
        $info->{linked}    = 1;
        $info->{id}        = $list->{id};
        $info->{name}      = $list->{name};
        $info->{is_public} = $list->{is_public};
        $info->{is_active} = $list->{is_active};
        unless ($list->{is_public}) {
            $info->{message} = 'List exists but is not public — it will not appear on Subscribe or My Subscriptions.';
        }
    } else {
        $info->{message} = qq{No active mailing list "$expected_name" on $sitename. Pick or create one below.};
    }
    return $info;
}

sub _get_site_id_for_sitename {
    my ($self, $c, $sitename) = @_;
    return unless $sitename;
    if ($sitename eq $self->_get_sitename($c)) {
        my $site_id = $self->_get_site_id($c);
        return $site_id if $site_id;
    }
    my $site_id;
    eval {
        my $site = $c->model('DBEncy')->resultset('Site')->find({ name => $sitename });
        $site_id = $site->id if $site;
    };
    return $site_id;
}

sub _slugify {
    my ($self, $text) = @_;
    return $self->_normalize_newsletter_page_code($self->_slug_base($text));
}

sub _absolute_uri {
    my ($self, $c, $path_uri) = @_;
    my $path = ref $path_uri ? $path_uri->path : "$path_uri";
    $path = '/' . $path unless $path =~ m{^/};
    my $base = $c->req->base;
    $base =~ s{/$}{};
    return "$base$path";
}

sub _get_sitename {
    my ($self, $c) = @_;
    return $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC';
}

sub _get_site_id {
    my ($self, $c) = @_;
    my $site_id = $c->session->{site_id} || $c->stash->{site_id};
    my $site_name = $self->_get_sitename($c);
    if (!$site_id && $site_name) {
        eval {
            my $site = $c->model('DBEncy')->resultset('Site')->find({ name => $site_name });
            $site_id = $site->id if $site;
        };
    }
    return $site_id;
}

sub _has_newsletter_admin_role {
    my ($self, $c) = @_;
    my $roles = $c->session->{roles} // '';
    my @flat;
    if (ref $roles eq 'ARRAY') {
        for my $r (@$roles) {
            push @flat, grep { $_ ne '' } split /\s*,\s*/, ($r // '');
        }
    } elsif ($roles) {
        push @flat, grep { $_ ne '' } split /\s*,\s*/, $roles;
    }
    return grep { /^(admin|editor)$/i } @flat;
}

__PACKAGE__->meta->make_immutable;
1;