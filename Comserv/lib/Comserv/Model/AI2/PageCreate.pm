package Comserv::Model::AI2::PageCreate;
# ===================================================================
# Phase 4 (Nov 5 2026): AI-made pages are saved ONLY as NEW drafts through
# Controller::Pages::create_page_record (the same code /pages/create uses).
# No scripts, no SQL, never overwrites an existing page.
#   save_draft($c, $pages_ctrl, \%fields)
#   try_chat_create($c, prompt => ...)   chat hook: "make a page about X"
# ===================================================================
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use Comserv::Model::AI2::ChatIntent qw(looks_like_page_create);

extends 'Catalyst::Model';

has 'logging' => (is => 'ro', default => sub { Comserv::Util::Logging->instance });

sub _slug {
    my ($s) = @_; $s = lc($s // ''); $s =~ s/[^a-z0-9]+/_/g; $s =~ s/^_+|_+$//g;
    return substr($s, 0, 60);
}

# Free page code: base, base_2, base_3 ... (never reuse an existing one).
sub free_page_code {
    my ($self, $c, $site, $base) = @_;
    $base = _slug($base) || 'ai_draft';
    my $rs = $c->model('DBEncy')->resultset('Page');
    for my $n (1 .. 50) {
        my $code = $n == 1 ? $base : "${base}_$n";
        return $code unless $rs->search({ sitename => $site, page_code => $code }, { rows => 1 })->single;
    }
    return $base . '_' . time;
}

sub save_draft {
    my ($self, $c, $pages, $f) = @_;
    my $site = $f->{sitename} || 'CSC';
    return { success => 0, error => 'Title and content are required.' }
        unless ($f->{title} // '') =~ /\S/ && ($f->{body} // '') =~ /\S/;
    require Comserv::Model::AI2::PageAssist;
    my $body = Comserv::Model::AI2::PageAssist->new->clean_html($f->{body});
    my $code = $self->free_page_code($c, $site, $f->{page_code} || $f->{title});
    my %data = (
        sitename    => $site,
        menu        => $f->{menu} || 'main',
        (defined $f->{submenu} && $f->{submenu} ne '' ? (submenu => $f->{submenu}) : ()),
        page_code   => $code,
        title       => substr($f->{title}, 0, 255),
        body        => $body,
        description => substr($f->{description} // '', 0, 255),
        keywords    => substr($f->{keywords} // '', 0, 255),
        link_order  => ($f->{link_order} // '') =~ /^\d+$/ ? $f->{link_order} : 0,
        status      => 'draft',                 # always draft
        roles       => 'admin',                 # hidden from visitors until published
        share_with  => '',
        created_by  => ($c->session->{username} || 'admin') . ' (AI draft)',
    );
    my $r = $pages->create_page_record($c, \%data);
    return $r unless $r->{success};
    return { success => 1, page_code => $code, status => 'draft',
             edit_url => '/pages/edit/' . $code, view_url => '/page/' . $code,
             message => "Saved a draft page '$data{title}'. Review and publish it here: /pages/edit/$code" };
}

sub _is_page_admin {
    my ($self, $c) = @_;
    my $pages = eval { $c->controller('Pages') } or return 0;
    return $pages->_check_admin_access($c) ? $pages : 0;
}

# Chat: "create/make/write a page about X". Admins only; drafts only.
sub try_chat_create {
    my ($self, $c, %a) = @_;
    my $topic = looks_like_page_create($a{prompt}) or return;
    my $pages = $self->_is_page_admin($c);
    return { handled => 1, success => 1, model => '(page-create)', provider => 'ai2-page',
             response => 'Only site admins with page edit rights can create pages from chat.' } unless $pages;
    my $site = $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC';
    require Comserv::Model::AI2::PageAssist;
    my $w = eval { Comserv::Model::AI2::PageAssist->new->write_page($c, topic => $topic, notes => $a{prompt}, sitename => $site) };
    if ($@ || !$w || !$w->{success}) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'page_try_chat_create',
            'write_page failed: ' . ($@ || ($w && $w->{error}) || 'unknown'));
        return { handled => 1, success => 1, model => '(page-create)', provider => 'ai2-page',
                 response => 'I could not write the page right now: ' . (($w && $w->{error}) || 'AI writer failed') };
    }
    my $l = eval { Comserv::Model::AI2::PageAssist->new->suggest_links($c, sitename => $site, text => $w->{page}{body}) };
    my %pl = ($l && $l->{success}) ? %{ $l->{placement} } : ();
    my $r = $self->save_draft($c, $pages, { %{ $w->{page} }, %pl, sitename => $site });
    return { handled => 1, success => 1, model => $w->{model} // '(page-create)', provider => 'ai2-page',
             response => $r->{success} ? $r->{message} : ('Draft not saved: ' . $r->{error}), page_action => $r };
}

__PACKAGE__->meta->make_immutable;
1;
