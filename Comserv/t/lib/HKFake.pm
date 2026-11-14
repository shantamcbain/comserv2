package HKFake;
# Tiny in-memory stand-ins for DBIC rows/resultsets and a Catalyst $c (tests only).
use strict; use warnings;

package HKFake::Row;
our $AUTOLOAD;
sub new { my ( $c, %a ) = @_; bless {%a}, $c }
sub AUTOLOAD { my $s = shift; ( my $n = $AUTOLOAD ) =~ s/.*:://; return if $n eq 'DESTROY'; $s->{$n} = shift if @_; $s->{$n} }
sub can { my ( $s, $m ) = @_; return ref $s && exists $s->{$m} ? sub { $_[0]{$m} } : $s->SUPER::can($m) }
sub get_columns { my $s = shift; map { $_ => $s->{$_} } grep { !/^_/ && !ref $s->{$_} } keys %$s }
sub get_column  { $_[0]{ $_[1] } }
sub update { my ( $s, $u ) = @_; $HKFake::WRITES++; $s->{$_} = $u->{$_} for keys %$u; $s }
sub lines { my $s = shift; HKFake::RS->new( 'lines', @{ $s->{_lines} || [] } ) }

package HKFake::RS;
sub new { my ( $c, $t, @r ) = @_; bless { t => $t, rows => [@r] }, $c }
sub _match {
    my ( $r, $q ) = @_;
    for my $k ( keys %$q ) {
        my $v = $q->{$k};
        if ( $k eq '-or' ) { my @alts = ref $v eq 'ARRAY' ? @$v : (); my $hit = 0;
            while ( my ( $ak, $av ) = splice @alts, 0, 2 ) { $hit ||= _match( $r, { $ak => $av } ) } return 0 unless $hit; next }
        ( my $f = $k ) =~ s/^(?:me|meal_plan)\.//;
        my $have = $r->{$f};
        if ( ref $v eq 'HASH' ) {
            my ($op) = keys %$v; my $x = $v->{$op};
            if    ( $op eq '!=' )     { return 0 if !defined $x ? !defined $have : ( defined $have && $have eq $x ) }
            elsif ( $op eq '-in' )    { return 0 unless defined $have && grep { $_ eq $have } @$x }
            elsif ( $op eq '-between' ) { return 0 unless defined $have && $have ge $x->[0] && $have le $x->[1] }
            elsif ( $op eq 'like' )   { ( my $re = quotemeta $x ) =~ s/\\%/.*/g; return 0 unless defined $have && $have =~ /^$re$/i }
            next;
        }
        if ( !defined $v ) { return 0 if defined $have; next }
        return 0 unless defined $have && $have eq $v;
    }
    return 1;
}
sub search { my ( $s, $q ) = @_; HKFake::RS->new( $s->{t}, grep { _match( $_, $q || {} ) } @{ $s->{rows} } ) }
sub all    { @{ $_[0]{rows} } }
sub first  { $_[0]{rows}[0] }
sub single { $_[0]{rows}[0] }
sub next   { shift @{ $_[0]{rows} } }
sub count  { scalar @{ $_[0]{rows} } }
sub find   { my ( $s, $id ) = @_; ( grep { $_->{id} == $id } @{ $s->{rows} } )[0] }
sub create {
    my ( $s, $h ) = @_;
    die $HKFake::CREATE_DIE if $HKFake::CREATE_DIE;
    $HKFake::WRITES++;
    my $tbl = $HKFake::DB{ $s->{t} } ||= [];
    my $row = HKFake::Row->new( id => ( $HKFake::NEXT_ID{ $s->{t} }++ || 0 ) + 100, %$h );
    push @$tbl, $row; return $row;
}

package HKFake::Schema;
sub new { bless {}, shift }
sub resultset {
    my ( $s, $n ) = @_;
    die "no source $n\n" if $HKFake::MISSING{$n};
    HKFake::RS->new( $n, @{ $HKFake::DB{$n} ||= [] } );
}
sub txn_do { my ( $s, $code ) = @_; $code->() }
sub schema { $_[0] }

package HKFake::C;
sub new { my ( $c, %a ) = @_; bless { session => {}, stash => {}, config => {}, flash => {}, %a }, $c }
sub model   { HKFake::Schema->new }
sub session { $_[0]{session} }
sub stash   { my $s = shift; return $s->{stash} unless @_; my %h = @_; $s->{stash}{$_} = $h{$_} for keys %h; $s->{stash} }
sub config  { $_[0]{config} }
sub flash   { $_[0]{flash} }

1;
