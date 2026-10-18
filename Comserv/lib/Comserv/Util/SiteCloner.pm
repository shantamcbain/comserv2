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
        my $style = $body ? ($body->attr('style') // '') : '';
        my $inner = $body ? join('', map { ref $_ ? $_->as_HTML('<>&', undef, {}) : _esc($_) } $body->content_list) : '';
        $inner = qq{<div class="site-clone" data-source="$url" style="$style">$inner</div>};
        $self->{pages}{$code} = { title => $title, body => $inner, url => $url,
            description => $desc_el ? $desc_el->attr('content') : undef,
            keywords => $kw_el ? $kw_el->attr('content') : undef };
        push @{$self->{order}}, $code;
        $self->{log}->("fetched $url -> $code");
        $tree->delete;
    }
    $self->_save_pages;
    return { pages => [ @{$self->{order}} ], images => scalar(grep { defined } values %{$self->{images}}), errors => $self->{errors} };
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
    my $name = URI::Escape::uri_unescape((split m{/}, $abs->path)[-1] // 'image');
    $name =~ s/\.[^.]+$//; $name =~ s/[^A-Za-z0-9._-]+/_/g; $name =~ s/^_+|_+$//g; $name ||= 'image';
    my $rel = URI->new($abs->path)->path; $rel =~ s{^/}{}; $rel =~ s{/[^/]*$}{};
    $rel =~ s/[^A-Za-z0-9]+/_/g; $name = "${rel}__$name" if length $rel && $rel ne 'images';
    $name .= ".$ext";
    my $full = "$self->{dir}/$name";
    my $data = $res->content;
    open(my $fh, '>:raw', $full) or do { push @{$self->{errors}}, "write $full: $!"; return $self->{images}{$key} = undef };
    print $fh $data; close $fh;
    my %rec = (
        file_name => $name, file_type => ".$ext", file_data => '', site_id => $self->{site_id},
        reference_id => 0, category_id => 0, share_id => 0, description => "Imported from $key",
        upload_date => strftime('%Y-%m-%d %H:%M:%S', localtime), file_size => length($data),
        file_path => $full, file_url => '', file_status => 'active', file_format => $MIME{$ext},
        user_id => $self->{user_id}, nfs_path => $full, external_url => $key, access_level => 'public',
        source_type => 'web', sitename => $self->{sitename}, is_duplicate => 0, file_hash => sha256_hex($data),
    );
    my $rs = $self->{schema}->resultset('File');
    my $row = $rs->search({ nfs_path => $full, sitename => $self->{sitename} }, { rows => 1 })->single;
    if ($row) { delete $rec{upload_date}; $row->update(\%rec) } else { $row = $rs->create(\%rec) }
    $self->{log}->("image $key -> file #" . $row->id);
    return $self->{images}{$key} = '/media/file/' . $row->id . '/' . $name;
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
