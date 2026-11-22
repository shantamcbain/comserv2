use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

BEGIN {
    use_ok('Comserv::Controller::Navigation')
        or BAIL_OUT('Failed to load Navigation controller');
}

can_ok(
    'Comserv::Controller::Navigation',
    qw(
        toggle_link_visibility
        _viewer_sees_member_content
        _link_visible_to_viewer
        _hosted_catalog_visible_to_viewer
        _hosting_list_publicly_for_sitename
        clear_hosting_visibility_cache
    )
);

{
    package MockLinkRow;
    sub new { bless { public_visible => $_[1] }, shift }
    sub public_visible { $_[0]->{public_visible} }
}

my $nav = Comserv::Controller::Navigation->new;

{
    package MockRootLoggedOut;
    sub new { bless {}, shift }
    sub user_exists { 0 }
}

{
    package MockRootLoggedIn;
    sub new { bless {}, shift }
    sub user_exists { 1 }
}

{
    package MockC;
    sub new {
        my ( $class, %args ) = @_;
        bless {
            stash   => { is_admin => $args{is_admin} || 0 },
            session => { username => $args{username} // '' },
            root    => $args{root},
        }, $class;
    }
    sub stash   { $_[0]->{stash} }
    sub session { $_[0]->{session} }
    sub controller {
        my ( $self, $name ) = @_;
        return $name eq 'Root' ? $self->{root} : undef;
    }
}

subtest 'viewer access tiers' => sub {
    my $guest = MockC->new( root => MockRootLoggedOut->new );
    ok !$nav->_viewer_sees_member_content($guest), 'guest is not member viewer';

    my $member = MockC->new(
        username => 'coopuser',
        root     => MockRootLoggedIn->new,
    );
    ok $nav->_viewer_sees_member_content($member), 'logged-in user sees restricted content';

    my $admin = MockC->new(
        username => 'admin',
        is_admin => 1,
        root     => MockRootLoggedOut->new,
    );
    ok $nav->_viewer_sees_member_content($admin), 'admin sees restricted content even when guest session shape';
};

subtest 'link public_visible filtering' => sub {
    my $orig_ensure = \&Comserv::Controller::Navigation::_ensure_internal_links_public_visible_column;
    my $orig_has    = \&Comserv::Controller::Navigation::_internal_links_has_public_visible_column;
    my $has_col     = 1;
    no warnings 'redefine';
    *Comserv::Controller::Navigation::_ensure_internal_links_public_visible_column = sub { return; };
    *Comserv::Controller::Navigation::_internal_links_has_public_visible_column = sub { $has_col };

    my $guest = MockC->new( root => MockRootLoggedOut->new );
    my $member = MockC->new(
        username => 'coopuser',
        root     => MockRootLoggedIn->new,
    );

    ok $nav->_link_visible_to_viewer( $guest, { public_visible => 1 } ),
        'guest sees public link';
    ok !$nav->_link_visible_to_viewer( $guest, { public_visible => 0 } ),
        'guest does not see members-only link';
    ok $nav->_link_visible_to_viewer( $member, { public_visible => 0 } ),
        'logged-in user sees members-only link';

    $has_col = 0;
    ok $nav->_link_visible_to_viewer( $guest, { public_visible => 0 } ),
        'without column, guest still sees link (legacy default)';

    no warnings 'redefine';
    *Comserv::Controller::Navigation::_ensure_internal_links_public_visible_column = $orig_ensure;
    *Comserv::Controller::Navigation::_internal_links_has_public_visible_column = $orig_has;
};

subtest 'hosted catalogue list_publicly filtering' => sub {
    my $orig_ensure = \&Comserv::Controller::Navigation::_ensure_hosting_list_publicly_column;
    my $orig_has    = \&Comserv::Controller::Navigation::_hosting_has_list_publicly_column;
    my $orig_list   = \&Comserv::Controller::Navigation::_hosting_list_publicly_for_sitename;
    my $has_col     = 1;
    my %public_list = ( brew => 0, coop => 1 );
    no warnings 'redefine';
    *Comserv::Controller::Navigation::_ensure_hosting_list_publicly_column = sub { return; };
    *Comserv::Controller::Navigation::_hosting_has_list_publicly_column = sub { $has_col };
    *Comserv::Controller::Navigation::_hosting_list_publicly_for_sitename = sub {
        my ( $self, $c, $sitename ) = @_;
        return 1 unless $has_col;
        return $public_list{ lc( $sitename // '' ) } // 1;
    };

    my $guest = MockC->new( root => MockRootLoggedOut->new );
    my $member = MockC->new(
        username => 'coopuser',
        root     => MockRootLoggedIn->new,
    );

    ok !$nav->_hosted_catalog_visible_to_viewer( $guest, 'Brew' ),
        'guest does not see site hidden from public catalogue';
    ok $nav->_hosted_catalog_visible_to_viewer( $guest, 'COOP' ),
        'guest sees publicly listed site';
    ok $nav->_hosted_catalog_visible_to_viewer( $member, 'Brew' ),
        'logged-in user sees site hidden from guests';

    $has_col = 0;
    ok $nav->_hosted_catalog_visible_to_viewer( $guest, 'Brew' ),
        'without column, guest sees all sites (legacy default)';

    no warnings 'redefine';
    *Comserv::Controller::Navigation::_ensure_hosting_list_publicly_column = $orig_ensure;
    *Comserv::Controller::Navigation::_hosting_has_list_publicly_column = $orig_has;
    *Comserv::Controller::Navigation::_hosting_list_publicly_for_sitename = $orig_list;
};


# CSC-20260914-6545: built-in Manufacturing Traveler shortcut when DB has none.
{
    my $user_rank = $nav->_role_rank('user');
    my $guest_rank = $nav->_role_rank('guest');
    my @none;
    $nav->_add_builtin_traveler_shortcut(\@none, $user_rank);
    is(scalar @none, 1, 'adds builtin traveler when list is empty');
    is($none[0]{url}, '/Accounting/manufacturing', 'builtin traveler URL');
    ok(grep { $_ eq 'traveler' } @{ $none[0]{trigger_phrases} || [] }, 'traveler trigger present');

    my @guest;
    $nav->_add_builtin_traveler_shortcut(\@guest, $guest_rank);
    is(scalar @guest, 0, 'guests do not get the traveler shortcut');

    my @existing = ({
        label => 'Manufacturing Traveler',
        url => '/Accounting/manufacturing',
        trigger_phrases => ['traveler'],
    });
    $nav->_add_builtin_traveler_shortcut(\@existing, $user_rank);
    is(scalar @existing, 1, 'does not duplicate when a DB row already covers traveler');
}

done_testing;
