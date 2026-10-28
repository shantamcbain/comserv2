# Test file with database credential retrieval
use Comserv::Model::RemoteDB;
my $db_config = Comserv::Model::RemoteDB->get_db_config('default');
my $dsn = $db_config->{dsn};
print "Login successful";
