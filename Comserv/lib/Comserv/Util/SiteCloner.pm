package Comserv::Util::SiteCloner;
# Clone an existing public website into the Page system of a Comserv site.
# - crawls same-host HTML pages (polite delay, page limit)
# - images are filed into NFS /data/nfs/<site>/media/site-import/ with File rows
#   (same fields as Model::File::upload_and_record) and served by /media/file/<id>/<name>
# - internal links become /page/<code>; index page becomes page_code 'home'
# - idempotent: re-runs update existing page/file rows (matched by sitename+page_code / nfs_path)
use strict;
use warnings;
use LWP::UserAgent;
use HTML::TreeBuilder;
use URI;
use Digest::SHA qw(sha256_hex);
use Encode qw(decode);
use File::Path qw(make_path);
use POSIX qw(strftime);

my %MIME = (jpg=>'image/jpeg', jpeg=>'image/jpeg', png=>'image/png', gif=>'image/gif', webp=>'image/webp');

sub new {
    my ($class, %a) = @_;
    my $self = bless {
        schema    => $a{schema},           # DBIx::Class schema (DBEncy)
        sitename  => $a{sitename},
        site_id   => $a{site_id} // 0,
        user_id   => $a{user_id} // 0,
        created_by=> $a{created_by} // 'site_cloner',
        nfs_root  => $a{nfs_root} // '/data/nfs',
        max_pages => $a{max_pages} // 200,
        delay     => $a{delay} // 1,
        log       => $a{log} // sub { print STDERR "$_[0]\n" },
        pages => {}, images => {}, errors => [], order => [],
    }, $class;
    $self->{ua} = LWP::UserAgent->new(agent => 'Comserv-SiteCloner/1.0', timeout => 30, max_size => 20_000_000);
    return $self;
}

sub _norm {
    my ($u) = @_;
    $u = URI->new($u)->canonical; $u->fragment(undef);
    my $p = $u->path; $p = '/' if $p eq '';
    $p =~ s{/index\.html?$}{/}i; $u->path($p);
    return $u->as_string;
}

sub page_code_for {
    my ($self, $u) = @_;
    my $p = URI::Escape::uri_unescape(URI->new($u)->path); $p =~ s{^/}{};
    $p =~ s{\.(html?|php|aspx?)$}{}i; $p =~ s{/$}{};
    return 'home' if $p eq '' || $p =~ /^index$/i;
    $p = lc $p; $p =~ s{[^a-z0-9]+}{_}g; $p =~ s{^_|_$}{}g;
    return $p || 'home';
}

sub _is_internal_page {
    my ($self, $u) = @_;
    return 0 unless $u->scheme && $u->scheme =~ /^https?$/;
    my $h = lc $u->host; $h =~ s/^www\.//;
    return 0 unless $h eq $self->{host};
    my $p = $u->path;
    return 0 if $p =~ /\.[a-z0-9]+$/i && $p !~ /\.(html?|php|aspx?)$/i;
    return 1;
}

sub clone {
    my ($self, $start) = @_;
    my $su = URI->new($start); $self->{host} = lc $su->host; $self->{host} =~ s/^www\.//;
    $self->{dir} = "$self->{nfs_root}/" . lc($self->{sitename}) . "/media/site-import";
    make_path($self->{dir}) unless -d $self->{dir};
    my @queue = (_norm($start)); my %seen = ($queue[0] => 1);
    while (my $url = shift @queue) {
        last if keys(%{$self->{pages}}) >= $self->{max_pages};
        sleep $self->{delay} if $self->{delay};
        my $res = $self->{ua}->get($url);
        unless ($res->is_success && ($res->content_type // '') =~ /html/) {
            push @{$self->{errors}}, "$url: " . $res->status_line; next;
        }
        my $html = $res->decoded_content // decode('UTF-8', $res->content, Encode::FB_DEFAULT);
        my $tree = HTML::TreeBuilder->new; $tree->ignore_unknown(0); $tree->parse($html); $tree->eof;
        my $base = $res->base;
        my $code = $self->page_code_for($url);
        my $title = $tree->look_down(_tag => 'title'); $title = $title ? $title->as_trimmed_text : $code;
        $title =~ s/\s+/ /g; $title ||= $code;
        my ($desc_el) = $tree->look_down(_tag => 'meta', name => qr/^description$/i);
        my ($kw_el)   = $tree->look_down(_tag => 'meta', name => qr/^keywords$/i);
        my @css_links;
        for my $l ($tree->look_down(_tag => 'link', rel => qr/stylesheet/i, href => qr/./)) {
            my $f = $self->_import_css(URI->new_abs($l->attr('href'), $base));
            push @css_links, $f if $f;
        }
        $_->delete for $tree->look_down(_tag => qr/^(script|noscript|iframe|link|style|meta)$/);
        $_->delete for $tree->look_down(id => 'fb-root');
        $_->delete for $tree->look_down(class => qr/\bfb-(like|share-button)\b/);
        # links
        for my $a ($tree->look_down(_tag => 'a', href => qr/./)) {
            my $href = $a->attr('href'); next if $href =~ /^(mailto|tel|javascript):/i;
            my $abs = URI->new_abs($href, $base);
            if ($self->_is_internal_page($abs)) {
                my $n = _norm($abs);
                push @queue, $n unless $seen{$n}++;
                my $frag = $abs->fragment; my $pc = $self->page_code_for($n);
                $a->attr(href => "/page/$pc" . (defined $frag && length $frag ? "#$frag" : ''));
            } elsif ($abs->path =~ /\.(jpe?g|png|gif|webp)$/i && lc($abs->host // '') =~ /\Q$self->{host}\E$/) {
                my $f = $self->_import_image($abs); $a->attr(href => $f) if $f;
            } else { $a->attr(href => $abs->as_string); }
        }
        for my $img ($tree->look_down(_tag => 'img', src => qr/./)) {
            my $abs = URI->new_abs($img->attr('src'), $base);
            my $f = $self->_import_image($abs);
            $img->attr(src => $f) if $f;
        }
        my $body = $tree->look_down(_tag => 'body');
        $self->{body_style} //= $body ? ($body->attr('style') // '') : '';
        $self->{css_files} ||= [ @css_links ];
        # Site-wide header/footer become the theme's site_header/site_footer page rows (taken once,
        # from the first page); they are removed from every page body so content is page-only.
        my ($hdr) = $tree->look_down(sub { my $e = shift; ($e->tag eq 'header') || (($e->attr('id')//'') =~ /^(header|masthead|top)$/i) });
        my ($ftr) = $tree->look_down(sub { my $e = shift; ($e->tag eq 'footer') || (($e->attr('id')//'') =~ /^(footer|navbottom)$/i) });
        my $html_of = sub { my $e = shift; $e->as_HTML('<>&', undef, {}) };
        if ($hdr) { $self->{site_header} //= $html_of->($hdr); $hdr->delete }
        if ($ftr) {
            # keep trailing copyright etc. that sits beside the footer nav
            my $extra = '';
            for my $sib ($ftr->right) { next unless ref $sib; $extra .= $html_of->($sib); $sib->delete; }
            $self->{site_footer} //= $html_of->($ftr) . $extra; $ftr->delete;
        }
        my ($wrap) = $tree->look_down(id => qr/^(wrapper|container|page|main)$/i);
        my $root = $wrap || $body;
        my $inner = $root ? join('', map { ref $_ ? $html_of->($_) : _esc($_) } $root->content_list) : '';
        $inner =~ s/^\s+|\s+$//g;
        $self->{pages}{$code} = { title => $title, body => $inner, url => $url,
            description => $desc_el ? $desc_el->attr('content') : undef,
            keywords => $kw_el ? $kw_el->attr('content') : undef };
        push @{$self->{order}}, $code;
        $self->{log}->("fetched $url -> $code");
        $tree->delete;
    }
    $self->_save_pages;
    $self->_save_theme;
    return { theme_css => $self->{theme_css}, pages => [ @{$self->{order}} ], images => scalar(grep { defined } values %{$self->{images}}), errors => $self->{errors} };
}

sub _esc { my $t = shift; $t =~ s/&/&amp;/g; $t =~ s/</&lt;/g; $t =~ s/>/&gt;/g; $t }

sub _import_image {
    my ($self, $abs) = @_;
    my $key = $abs->canonical->as_string;
    return $self->{images}{$key} if exists $self->{images}{$key};
    my ($ext) = lc($abs->path) =~ /\.([a-z0-9]+)$/;
    my $res = $self->{ua}->get($key);
    unless ($res->is_success) { push @{$self->{errors}}, "image $key: " . $res->status_line; return $self->{images}{$key} = undef; }
    my $ct = ($res->content_type // ''); unless ($ext && $MIME{$ext}) { ($ext) = $ct =~ m{image/(\w+)}; $ext = 'jpg' if ($ext//'') eq 'jpeg'; }
    unless ($ext && $MIME{$ext}) { push @{$self->{errors}}, "image $key: unsupported type $ct"; return $self->{images}{$key} = undef; }
    my $name = $self->_local_name($abs, $ext);
    my $f = $self->_store($key, $name, $ext, $MIME{$ext}, $res->content);
    $self->{log}->("image $key -> $f") if $f;
    return $self->{images}{$key} = $f;
}

# Import a stylesheet: its url() assets are filed first and rewritten to /media/file/<id>/<name>.
sub _import_css {
    my ($self, $abs) = @_;
    my $key = $abs->canonical->as_string;
    return $self->{css}{$key} if exists $self->{css}{$key};
    my $res = $self->{ua}->get($key);
    unless ($res->is_success) { push @{$self->{errors}}, "css $key: " . $res->status_line; return $self->{css}{$key} = undef; }
    my $css = $res->decoded_content // $res->content;
    $css =~ s{url\(\s*(['"]?)([^'")]+)\1\s*\)}{
        my ($q, $u) = ($1, $2);
        my $f = ($u =~ /^data:/i) ? undef : $self->_import_image(URI->new_abs($u, $key));
        $f ? "url($f)" : ($u =~ /^data:/i ? "url($q$u$q)" : 'url(' . URI->new_abs($u, $key) . ')');
    }ge;
    my $name = $self->_local_name($abs, 'css');
    my $f = $self->_store($key, $name, 'css', 'text/css', Encode::encode('UTF-8', $css));
    $self->{log}->("css $key -> $f") if $f;
    return $self->{css}{$key} = $f;
}

sub _local_name {
    my ($self, $abs, $ext) = @_;
    my $name = URI::Escape::uri_unescape((split m{/}, $abs->path)[-1] // 'file');
    $name =~ s/\.[^.]+$//; $name =~ s/[^A-Za-z0-9._-]+/_/g; $name =~ s/^_+|_+$//g; $name ||= 'file';
    my $rel = URI->new($abs->path)->path; $rel =~ s{^/}{}; $rel = ($rel =~ m{^(.*)/[^/]*$}) ? $1 : '';
    $rel =~ s/[^A-Za-z0-9]+/_/g; $name = "${rel}__$name" if length $rel && $rel ne 'images';
    return "$name.$ext";
}

# Write bytes to NFS site-import dir and create/update the File Manager row (matched by nfs_path).
sub _store {
    my ($self, $key, $name, $ext, $mime, $data) = @_;
    my $full = "$self->{dir}/$name";
    open(my $fh, '>:raw', $full) or do { push @{$self->{errors}}, "write $full: $!"; return };
    print $fh $data; close $fh;
    my %rec = (
        file_name => $name, file_type => ".$ext", file_data => '', site_id => $self->{site_id},
        reference_id => 0, category_id => 0, share_id => 0, description => "Imported from $key",
        upload_date => strftime('%Y-%m-%d %H:%M:%S', localtime), file_size => length($data),
        file_path => $full, file_url => '', file_status => 'active', file_format => $mime,
        user_id => $self->{user_id}, nfs_path => $full, external_url => $key, access_level => 'public',
        source_type => 'web', sitename => $self->{sitename}, is_duplicate => 0, file_hash => sha256_hex($data),
    );
    my $rs = $self->{schema}->resultset('File');
    my $row = $rs->search({ nfs_path => $full, sitename => $self->{sitename} }, { rows => 1 })->single;
    if ($row) { delete $rec{upload_date}; $row->update(\%rec) } else { $row = $rs->create(\%rec) }
    return '/media/file/' . $row->id . '/' . $name;
}

# Theme: site_header / site_footer page rows + a site-scoped copy of the original CSS
# (every selector prefixed with body.theme-<site>) filed in the File Manager. The app theme
# root/static/css/themes/<site>.css @imports that file (written here when the tree is writable).
sub _save_theme {
    my ($self) = @_;
    my $site = lc $self->{sitename}; $site =~ s/[^a-z0-9]+//g;
    my $rs = $self->{schema}->resultset('Page');
    my $now = strftime('%Y-%m-%d %H:%M:%S', localtime);
    for my $part ([site_header => $self->{site_header}], [site_footer => $self->{site_footer}]) {
        my ($code, $html) = @$part; next unless defined $html;
        my %rec = (sitename => $self->{sitename}, page_code => $code, title => "$self->{sitename} $code",
            body => $html, menu => 'Theme', link_order => 0, status => 'active', roles => 'public',
            page_type => $code, updated_at => $now);
        my $row = $rs->search({ sitename => $self->{sitename}, page_code => $code }, { rows => 1 })->single;
        if ($row) { $row->update(\%rec) } else { $rs->create({ %rec, created_by => $self->{created_by}, created_at => $now }) }
    }
    my $scoped = '';
    for my $f (@{$self->{css_files} || []}) {
        my ($id) = $f =~ m{/media/file/(\d+)/}; next unless $id;
        my $row = $self->{schema}->resultset('File')->find($id) or next;
        open(my $fh, '<:raw', $row->nfs_path) or next; local $/; my $css = <$fh>; close $fh;
        $scoped .= scope_css($css, "body.theme-$site") . "\n";
    }
    $scoped .= "body.theme-$site { $self->{body_style} }\n" if $self->{body_style};
    return unless length $scoped;
    my $name = "theme-$site.css";
    $self->{theme_css} = $self->_store("theme:$self->{sitename}", $name, 'css', 'text/css', $scoped);
    $self->{log}->("theme css -> $self->{theme_css}");
}

sub scope_css {
    my ($css, $scope) = @_;
    $css =~ s{/\*.*?\*/}{}gs; $css =~ s/\@charset[^;]*;//g;
    my $out = '';
    while ($css =~ /\G\s*([^{}]+?)\s*\{([^{}]*)\}/gc) {
        my ($sel, $decl) = ($1, $2);
        next if $sel =~ /^\@/;    # simple @-rules dropped (media blocks handled by regex skip)
        my @s = map {
            my $x = $_; $x =~ s/^\s+|\s+$//g;
            $x =~ /^(html|body)\b(.*)$/i ? "$scope$2" : "$scope $x"
        } split /,/, $sel;
        $out .= join(', ', @s) . " {$decl}\n";
    }
    return $out;
}

sub _save_pages {
    my ($self) = @_;
    my $rs = $self->{schema}->resultset('Page');
    my $now = strftime('%Y-%m-%d %H:%M:%S', localtime);
    my $i = 0;
    for my $code (@{$self->{order}}) {
        my $p = $self->{pages}{$code}; $i++;
        my %rec = (sitename => $self->{sitename}, page_code => $code, title => substr($p->{title},0,255),
            body => $p->{body}, description => $p->{description}, keywords => $p->{keywords},
            menu => 'Main', link_order => $i * 10, status => 'active', roles => 'public',
            page_type => 'standard', updated_at => $now);
        my $row = $rs->search({ sitename => $self->{sitename}, page_code => $code }, { rows => 1 })->single;
        if ($row) { $row->update(\%rec) } else { $rs->create({ %rec, created_by => $self->{created_by}, created_at => $now }) }
    }
}
use URI::Escape ();
1;
