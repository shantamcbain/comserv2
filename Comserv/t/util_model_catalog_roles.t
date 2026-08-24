#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Comserv::Util::ModelCatalog;

{
    package MockC;
    sub new { my ($class, $roles) = @_; bless { session => { roles => $roles } }, $class }
    sub session { $_[0]->{session} }
    sub stash   { $_[0]->{stash} ||= {} }
    sub path_to {
        my ($self, @parts) = @_;
        require File::Spec;
        return File::Spec->catfile($FindBin::Bin, '..', @parts);
    }
}

sub rank_for {
    my ($roles) = @_;
    return Comserv::Util::ModelCatalog->display_rank(MockC->new($roles));
}

is(rank_for([]), 0, 'empty roles = guest');
is(rank_for(['guest']), 0, 'guest role = guest');
is(rank_for(['member']), 1, 'member = rank 1');
is(rank_for(['editor']), 1, 'editor shares member rank');
is(rank_for(['developer']), 2, 'developer = priv');
is(rank_for(['admin']), 2, 'admin = priv');

my $guest = MockC->new([]);
ok(Comserv::Util::ModelCatalog->agent_allowed($guest, 'general'), 'guest: general');
ok(Comserv::Util::ModelCatalog->agent_allowed($guest, 'helpdesk'), 'guest: helpdesk');
ok(!Comserv::Util::ModelCatalog->agent_allowed($guest, 'ency'), 'guest: no ency');
ok(!Comserv::Util::ModelCatalog->agent_allowed($guest, 'coding'), 'guest: no coding');
ok(!Comserv::Util::ModelCatalog->can_select_model($guest), 'guest cannot select model');

my $member = MockC->new(['member']);
ok(Comserv::Util::ModelCatalog->agent_allowed($member, 'ency'), 'member: ency');
ok(!Comserv::Util::ModelCatalog->agent_allowed($member, 'coding'), 'member: no coding');
ok(!Comserv::Util::ModelCatalog->can_select_model($member), 'member cannot select model');

my $editor = MockC->new(['editor']);
ok(Comserv::Util::ModelCatalog->agent_allowed($editor, 'ency'), 'editor: ency');
ok(!Comserv::Util::ModelCatalog->agent_allowed($editor, 'planning'), 'editor: no planning');
ok(!Comserv::Util::ModelCatalog->can_select_model($editor), 'editor cannot select model');

my $dev = MockC->new(['developer']);
ok(Comserv::Util::ModelCatalog->agent_allowed($dev, 'coding'), 'developer: coding');
ok(Comserv::Util::ModelCatalog->can_select_model($dev), 'developer can select model');

my $site_admin = MockC->new(['user']);
$site_admin->{session}{is_admin} = 1;
ok(Comserv::Util::ModelCatalog->can_select_model($site_admin), 'session is_admin is priv');
is(Comserv::Util::ModelCatalog->_role_tier($site_admin), 'priv', 'session is_admin tier');

done_testing();
