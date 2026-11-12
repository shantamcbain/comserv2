use strict; use warnings;
use Test::More;
use File::Temp qw(tempdir);
use lib 'lib';
use Comserv::Util::BotIdentity;

my $id = Comserv::Util::BotIdentity->identity_for('codeguard');
is $id->{name}, 'Code Guard', 'mapped name';
$id = Comserv::Util::BotIdentity->identity_for('brand-new-branch');
is $id->{name},  'brand-new-branch bot', 'default name';
is $id->{email}, 'brand-new-branch@workstation.local', 'default email';
is(Comserv::Util::BotIdentity->identity_for('/home/x/.grok/worktrees/p/abc')->{name}, 'Grok Bot', 'grok path');
is(Comserv::Util::BotIdentity->identity_for('/home/x/.comserv/worktrees/helpdesk/Comserv')->{name}, 'HelpDesk', 'path form');

my $t = tempdir(CLEANUP => 1);
local $ENV{HOME} = $t; local $ENV{GIT_CONFIG_GLOBAL} = "$t/gc"; local $ENV{GIT_CONFIG_NOSYSTEM} = 1;
sub sh { system(@_) == 0 or BAIL_OUT("cmd failed: @_") }
sh('git','init','-q',"$t/r"); sh('git','-C',"$t/r",'-c','user.name=x','-c','user.email=x@x','commit','-q','--allow-empty','-m','i');
sh('git','-C',"$t/r",'worktree','add','-q',"$t/w",'-b','newbot');
ok(Comserv::Util::BotIdentity->apply("$t/w", 'newbot'), 'apply ok');
my $who = `git -C $t/w var GIT_AUTHOR_IDENT`; like $who, qr/^newbot bot <newbot\@workstation\.local>/, 'new worktree commits as bot';
$who = `git -C $t/r var GIT_AUTHOR_IDENT`; unlike $who, qr/newbot bot/, 'other worktree unaffected' ;
ok(!Comserv::Util::BotIdentity->apply("$t/nope", 'x'), 'bad dir returns 0');
done_testing;
