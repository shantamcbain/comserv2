# Test file with database credential retrieval
use Comserv::Model::RemoteDB;
my $db_config = Comserv::Model::RemoteDB->get_db_config('default');
print "Login successful";
