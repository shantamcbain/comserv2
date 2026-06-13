use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Spec;
use File::Path qw(remove_tree make_path);

BEGIN {
    use_ok('Comserv::Controller::Documentation')
        or BAIL_OUT('Failed to load Documentation controller');
}

my $tmp = File::Spec->catdir($Bin, 'tmp_doc_config_test');
remove_tree($tmp) if -d $tmp;
make_path($tmp);

local $ENV{COMSERV_DOC_CONFIG_DIR} = $tmp;

my $shipped = File::Spec->catfile($FindBin::Bin, '..', 'root', 'Documentation', 'config', 'DocumentationConfig.json');
ok(-e $shipped, 'shipped documentation config exists in repo');

{
    package MockContext;
    sub new { bless { root => $FindBin::Bin . '/..' }, shift }
    sub path_to {
        my ($self, @parts) = @_;
        return File::Spec->catdir($self->{root}, @parts);
    }
    sub can { return $_[1] eq 'path_to' }
}

my $c = MockContext->new;
my $write = Comserv::Controller::Documentation::_documentation_config_write_path($c);

is($write, File::Spec->catfile($tmp, 'DocumentationConfig.json'), 'write path uses COMSERV_DOC_CONFIG_DIR');

ok(Comserv::Controller::Documentation::_atomic_write_json(
    $write, { pages => { demo => { title => 'Demo' } }, categories => {} }
), 'atomic write to writable dir succeeds');

my $read = Comserv::Controller::Documentation::_documentation_config_read_path($c);
is($read, $write, 'read path prefers writable overlay after write');

remove_tree($tmp);
done_testing();