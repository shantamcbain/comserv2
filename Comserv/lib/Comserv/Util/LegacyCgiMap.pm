package Comserv::Util::LegacyCgiMap;
# Pure, DB-free resolver for old /cgi-bin URLs. No Catalyst dependency so it can be unit-tested.
use strict;
use warnings;
use JSON::PP ();

sub load {
    my ($class, $file) = @_;
    open my $fh, '<:raw', $file or die "legacy map $file: $!";
    local $/; my $json = <$fh>; close $fh;
    my $map = JSON::PP->new->relaxed->decode($json);
    die "legacy map: no scripts" unless ref $map->{scripts} eq 'HASH';
    for my $s (values %{ $map->{scripts} }) {          # precompile regexes once
        for my $r (@{ $s->{rules} || [] }) {
            $r->{_re}    = [ map { [ qr/$_->[0]/i, $_->[1] ] } @{ $r->{regex} || [] } ];
            $r->{_match} = qr/$r->{match}/ if defined $r->{match};
        }
    }
    return bless { map => $map }, $class;
}

# '/cgi-bin/index.cgi/cgi-bin/index.cgi' -> 'index.cgi'; '/cgi-bin/' -> 'index.cgi'
sub script_from_path {
    my ($path) = @_;
    $path //= '';
    $path =~ s{^.*/?cgi-bin(?:/|$)}{}is;                 # keep text after the LAST cgi-bin/
    $path =~ s{^/+}{};
    return 'index.cgi' if $path eq '' || $path =~ m{^\?};
    if ($path =~ m{^((?:[^/]+/)?[^/]+?\.(?:cgi|pl))(?:/|$)}i) { $path = $1 }
    return lc $path;
}

sub parse_query {
    my ($qs) = @_;
    my %q;
    $qs = substr($qs // '', 0, 4000);
    for my $kv (split /[&;]/, $qs) {
        next unless length $kv;
        my ($k, $v) = split /=/, $kv, 2;
        $k = _unesc($k); $v = _unesc($v // '');
        $k =~ s/^\?+//;
        $k = lc $k;
        next if $k eq '' || $k eq 'session_id';
        $q{$k} = $v unless exists $q{$k};
    }
    return \%q;
}

sub _unesc { my $s = shift; $s =~ tr/+/ /; $s =~ s/%([0-9A-Fa-f]{2})/chr hex $1/ge; return $s }

# Returns (target, reason). target is a path starting with '/' or the string '410'.
sub resolve {
    my ($self, $path, $qs) = @_;
    my $map    = $self->{map};
    my $script = script_from_path($path);
    my $q      = parse_query($qs);
    my $s      = $map->{scripts}{$script};
    $s = $map->{scripts}{ $s->{alias} } if $s && $s->{alias};
    return ($map->{default} // '410', "unmapped-script:$script") unless $s;
    my $site = lc($q->{site} // '');
    my $pick = sub {                     # per-site targets: { "bmaster": "/x", "*": "/y" }
        my $t = shift;
        return $t unless ref $t eq 'HASH';
        return exists $t->{$site} ? $t->{$site} : $t->{'*'};
    };
    for my $r (@{ $s->{rules} || [] }) {
        my $p = lc $r->{param};
        next unless exists $q->{$p};
        my $v = lc $q->{$p};
        if ($r->{values} && exists $r->{values}{$v}) {
            my $t = $pick->($r->{values}{$v});
            return ($t, "$script|$p=$v") if defined $t;
        }
        for my $rx (@{ $r->{_re} }) { return ($rx->[1], "$script|$p~$v") if $v =~ $rx->[0] }
        if ($r->{_match}) {
            if ($q->{$p} =~ $r->{_match}) { (my $t = $r->{to}) =~ s/\{value\}/$q->{$p}/; return ($t, "$script|$p=N") }
        }
        elsif (defined $r->{to}) { return ($r->{to}, "$script|$p") }
        return ($r->{else}, "unmapped:$script|$p=$v") if defined $r->{else};
    }
    return ($s->{default} // $map->{default} // '410', "$script|default");
}

1;
