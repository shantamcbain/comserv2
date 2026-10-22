package Comserv::Util::SiteTidy;
# Optional "Tidy up with AI" step after a site clone.
# Uses the app's own AI router (Model::AI2::Router->dispatch_chat, automatic cost-effective
# model selection) to propose: cleaned HTML, a unique title where titles are duplicated, and
# layout warnings. Proposals are stored as JSON next to the import
# (/data/nfs/<site>/media/site-import/ai-tidy.json) and nothing is applied until accepted.
use strict;
use warnings;
use JSON ();
use HTML::TreeBuilder;
use POSIX qw(strftime);

my $SYSTEM = <<'TXT';
You tidy legacy HTML for a content management system. Rules:
- Keep every word of the owner's visible text EXACTLY as written (same words, spelling, punctuation, order). Never add, remove or rewrite text. Never invent content.
- Keep all <img> tags with their src and alt, and all <a> tags with their href.
- Remove deprecated tags/attributes (font, center, align, hspace, vspace, bgcolor, border on img), presentational inline styles that only set fonts, and empty elements. Replace layout tables with simple divs only when it is clearly safe; keep data tables.
- Do not wrap the result in html/body tags.
Answer in exactly this plain-text format and nothing else:
TITLE: (a suggested title only if asked for one, otherwise leave blank; build it from words already on the page)
ISSUES:
- (one short line per layout problem you noticed, e.g. fixed pixel widths, images too wide for mobile, empty paragraphs)
HTML:
(the full cleaned HTML of the page, starting on the next line)
TXT

# TITLE:/ISSUES:/HTML: reply -> { title, issues => [], html }; JSON replies are accepted too.
sub parse_reply {
    my ($raw) = @_;
    $raw =~ s/^\s*```\w*\s*\n//; $raw =~ s/\n?```\s*$//;
    if ($raw =~ /^\s*\{/) { my $j = eval { JSON->new->decode($raw) }; return $j if ref $j eq 'HASH' && $j->{html}; }
    return unless $raw =~ /^\s*HTML:\s*$/mi || $raw =~ /^\s*HTML:/mi;
    my ($head, $html) = split /^\s*HTML:[ \t]*\n?/mi, $raw, 2;
    $html //= ''; $html =~ s/^\s*```\w*\s*\n//; $html =~ s/\n?```\s*$//; $html =~ s/^\s+|\s+$//g;
    return unless $html =~ /</ && $html !~ /^\(the full cleaned/i;
    my ($title) = $head =~ /^\s*TITLE:[ \t]*(.*)$/mi; $title //= ''; $title =~ s/^\(.*\)$//; $title =~ s/^\s+|\s+$//g;
    my @issues = grep { length && !/^\(one short line/i } map { my $x = $_; $x =~ s/^\s*[-*]\s*//; $x =~ s/\s+$//; $x } grep { /^\s*[-*]\s+/ } split /\n/, ($head // '');
    return { title => $title, issues => \@issues, html => $html };
}

sub new { my ($class, %a) = @_; bless { %a }, $class }

sub store_path {
    my ($self, $sitename) = @_;
    my $root = $self->{nfs_root} // '/data/nfs';
    return "$root/" . lc($sitename) . "/media/site-import/ai-tidy.json";
}

sub load {
    my ($self, $sitename) = @_;
    my $f = $self->store_path($sitename);
    return { site => $sitename, pages => {} } unless -f $f;
    open(my $fh, '<:raw', $f) or return { site => $sitename, pages => {} };
    local $/; my $j = <$fh>; close $fh;
    return eval { JSON->new->utf8->decode($j) } || { site => $sitename, pages => {} };
}

sub save {
    my ($self, $sitename, $data) = @_;
    my $f = $self->store_path($sitename);
    open(my $fh, '>:raw', "$f.tmp") or die "write $f: $!";
    print $fh JSON->new->utf8->canonical->pretty->encode($data); close $fh;
    rename "$f.tmp", $f or die "rename $f: $!";
}

sub visible_text {
    my ($html) = @_;
    my $t = HTML::TreeBuilder->new_from_content($html // '');
    my $s = $t->as_text; $t->delete;
    $s =~ s/\x{a0}/ /g; $s =~ s/\s+/ /g; $s =~ s/^ | $//g;
    return $s;
}

# run($c, $sitename, only => [codes], dry_run => 1) -> { proposals => n, model => ..., errors => [...] }
sub run {
    my ($self, $c, $sitename, %o) = @_;
    my $rs = $c->model('DBEncy')->resultset('Page');
    my @pages = $rs->search({ sitename => $sitename, page_type => 'standard', status => 'active' },
                            { order_by => 'link_order' })->all;
    @pages = grep { my $p = $_; grep { $_ eq $p->page_code } @{$o{only}} } @pages if $o{only};
    my %tcount; $tcount{ lc $_->title }++ for @pages;
    my $data = $self->load($sitename);
    my $router = $c->model('AI2::Router');
    my (@errors, %models, $n);
    for my $p (@pages) {
        my $dup = $tcount{ lc $p->title } > 1;
        my $prompt = ($dup ? "The title \"" . $p->title . "\" is shared with other pages; suggest a unique title from this page's own headings/text.\n"
                           : "Title is unique; return an empty title.\n")
                   . "Page code: " . $p->page_code . "\nHTML:\n" . $p->body;
        my $resp = eval { $router->dispatch_chat($c, $o{model}, [
                { role => 'system', content => $SYSTEM }, { role => 'user', content => $prompt } ],
                can_select => 1, log_usage => 'site_clone_tidy') };
        unless ($resp && $resp->{success}) {
            push @errors, $p->page_code . ': ' . ($@ || ($resp && $resp->{error}) || 'no response'); next;
        }
        my $raw = $resp->{response} // '';
        my $j = parse_reply($raw);
        unless ($j) {   # one retry: weaker free models sometimes answer with reasoning first
            my $r2 = eval { $router->dispatch_chat($c, $o{model}, [
                { role => 'system', content => $SYSTEM }, { role => 'user', content => $prompt },
                { role => 'assistant', content => substr($raw, 0, 2000) },
                { role => 'user', content => 'Reply again using ONLY the TITLE:/ISSUES:/HTML: format, no reasoning.' } ],
                can_select => 1, log_usage => 'site_clone_tidy') };
            if ($r2 && $r2->{success}) { $resp = $r2; $raw = $r2->{response} // ''; $j = parse_reply($raw); }
        }
        unless ($j) { push @errors, $p->page_code . ': unparseable AI reply (' . join('|', grep { defined } $resp->{provider}, $resp->{model}) . '): ' . substr($raw, 0, $ENV{TIDY_DEBUG} ? 3000 : 200); next; }
        my $before_t = visible_text($p->body); my $after_t = visible_text($j->{html});
        my $model = join('|', grep { defined } $resp->{provider}, $resp->{model}) || 'router-default';
        $models{$model}++;
        $data->{pages}{ $p->page_code } = {
            page_id => $p->id, status => 'pending', model => $model,
            created => strftime('%Y-%m-%d %H:%M:%S', localtime),
            old_title => $p->title, new_title => ($dup ? ($j->{title} // '') : ''),
            old_body => $p->body, new_body => $j->{html},
            issues => (ref $j->{issues} eq 'ARRAY' ? $j->{issues} : []),
            text_verbatim => ($before_t eq $after_t ? 1 : 0),
        };
        $n++;
    }
    $data->{site} = $sitename;
    $self->save($sitename, $data) unless $o{dry_run};
    return { proposals => $n // 0, models => \%models, errors => \@errors, data => $data };
}

# decide($c, $sitename, $code, 'accept'|'reject', %parts) - accept writes body (+title) to the page row.
sub decide {
    my ($self, $c, $sitename, $code, $action, %o) = @_;
    my $data = $self->load($sitename);
    my $pr = $data->{pages}{$code} or return (0, "No proposal for $code");
    return (0, "Proposal for $code already $pr->{status}") unless $pr->{status} eq 'pending';
    if ($action eq 'accept') {
        my $page = $c->model('DBEncy')->resultset('Page')->search({ sitename => $sitename, page_code => $code }, { rows => 1 })->single
            or return (0, "Page $code not found");
        return (0, "Page $code changed since the proposal; re-run tidy") if $page->body ne $pr->{old_body};
        return (0, "The AI changed the visible text of $code; tick 'accept anyway' after checking") unless $pr->{text_verbatim} || $o{force};
        my %upd = (body => $pr->{new_body}, updated_at => strftime('%Y-%m-%d %H:%M:%S', localtime));
        $upd{title} = substr($pr->{new_title}, 0, 255) if $o{with_title} && length($pr->{new_title} // '');
        $page->update(\%upd);
    }
    $pr->{status} = $action eq 'accept' ? 'accepted' : 'rejected';
    $pr->{decided} = strftime('%Y-%m-%d %H:%M:%S', localtime);
    $pr->{decided_by} = $o{user} // '';
    $self->save($sitename, $data);
    return (1, "$code $pr->{status}");
}
1;
