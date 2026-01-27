package Comserv::Controller::Admin::SchemaComparison;
use Moose;
use namespace::autoclean;

BEGIN { extends 'Catalyst::Controller'; }

use Try::Tiny;
use JSON qw(decode_json);
use Comserv::Util::Logging;
use Comserv::Util::AdminAuth;
use Data::Dumper;
use File::Slurp qw(read_file write_file);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use File::Find;

=head1 NAME

Comserv::Controller::Admin::SchemaComparison - Schema Comparison and Synchronization Controller

=head1 DESCRIPTION

Dedicated controller for schema comparison and bidirectional synchronization between database tables and Result files.

=cut

sub admin_auth {
    my ($self) = @_;
    return Comserv::Util::AdminAuth->new();
}

sub logging {
    my ($self) = @_;
    return Comserv::Util::Logging->new();
}

=head2 sync_table_to_result

Sync database table field to Result file

=cut

sub sync_table_to_result :Path('/schema-comparison/sync_table_to_result') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'sync_table_to_result',
        "Starting sync_table_to_result action");
    
    # Check admin auth with fallback
    my $is_auth = 0;
    if ($c->session->{username} && $c->session->{user_id}) {
        if ($c->session->{is_admin} || (ref($c->session->{roles}) eq 'ARRAY' && grep(/admin/i, @{$c->session->{roles}})) || 
            ($c->session->{roles} && $c->session->{roles} =~ /\badmin\b/i) ||
            (ref($c->session->{user_groups}) eq 'ARRAY' && grep(/admin/i, @{$c->session->{user_groups}})) ||
            ($c->session->{user_groups} && $c->session->{user_groups} =~ /\badmin\b/i)) {
            $is_auth = 1;
        }
    } elsif ($c->user && $c->user->check_roles(qw/admin/)) {
        $is_auth = 1;
    }
    
    unless ($is_auth) {
        $c->response->status(403);
        $c->stash(json => { success => 0, error => 'Access denied' });
        $c->forward('View::JSON');
        return;
    }
    
    my $json_data;
    try {
        my $body = $c->req->body;
        if ($body) {
            local $/;
            my $json_text = <$body>;
            $json_data = decode_json($json_text);
        } else {
            die "No request body provided";
        }
    } catch {
        $c->response->status(400);
        $c->stash(json => { success => 0, error => "Invalid JSON request: $_" });
        $c->forward('View::JSON');
        return;
    };
    
    my $table_name = $json_data->{table_name};
    my $field_name = $json_data->{field_name};
    my $database = $json_data->{database};
    
    unless ($table_name && $field_name && $database) {
        $c->response->status(400);
        $c->stash(json => { success => 0, error => 'Missing required parameters: table_name, field_name, database' });
        $c->forward('View::JSON');
        return;
    }
    
    try {
        my $table_field_info = $self->get_table_field_info($c, $table_name, $field_name, $database);
        my $result = $self->update_result_field_from_table($c, $table_name, $field_name, $database, $table_field_info);
        
        $c->stash(json => {
            success => 1,
            message => "Successfully synced table field '$field_name' to result file",
            field_info => $table_field_info
        });
        
    } catch {
        my $error = "Error syncing table to result: $_";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'sync_table_to_result', $error);
        
        $c->response->status(500);
        $c->stash(json => { success => 0, error => $error });
    };
    
    $c->forward('View::JSON');
}

=head2 sync_result_to_table

Sync Result file field to database table

=cut

sub sync_result_to_table :Path('/schema-comparison/sync_result_to_table') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'sync_result_to_table',
        "Starting sync_result_to_table action");
    
    # Check admin auth with fallback
    my $is_auth = 0;
    if ($c->session->{username} && $c->session->{user_id}) {
        if ($c->session->{is_admin} || (ref($c->session->{roles}) eq 'ARRAY' && grep(/admin/i, @{$c->session->{roles}})) || 
            ($c->session->{roles} && $c->session->{roles} =~ /\badmin\b/i) ||
            (ref($c->session->{user_groups}) eq 'ARRAY' && grep(/admin/i, @{$c->session->{user_groups}})) ||
            ($c->session->{user_groups} && $c->session->{user_groups} =~ /\badmin\b/i)) {
            $is_auth = 1;
        }
    } elsif ($c->user && $c->user->check_roles(qw/admin/)) {
        $is_auth = 1;
    }
    
    unless ($is_auth) {
        $c->response->status(403);
        $c->stash(json => { success => 0, error => 'Access denied' });
        $c->forward('View::JSON');
        return;
    }
    
    my $json_data;
    try {
        my $body = $c->req->body;
        if ($body) {
            local $/;
            my $json_text = <$body>;
            $json_data = decode_json($json_text);
        } else {
            die "No request body provided";
        }
    } catch {
        $c->response->status(400);
        $c->stash(json => { success => 0, error => "Invalid JSON request: $_" });
        $c->forward('View::JSON');
        return;
    };
    
    my $table_name = $json_data->{table_name};
    my $field_name = $json_data->{field_name};
    my $database = $json_data->{database};
    
    unless ($table_name && $field_name && $database) {
        $c->response->status(400);
        $c->stash(json => { success => 0, error => 'Missing required parameters: table_name, field_name, database' });
        $c->forward('View::JSON');
        return;
    }
    
    try {
        my $result_field_info = $self->get_result_field_info($c, $table_name, $field_name, $database);
        my $sql = $self->update_table_field_from_result($c, $table_name, $field_name, $database, $result_field_info);
        
        $c->stash(json => {
            success => 1,
            message => "Successfully synced result field '$field_name' to table",
            field_info => $result_field_info,
            sql => $sql
        });
        
    } catch {
        my $error = "Error syncing result to table: $_";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'sync_result_to_table', $error);
        
        $c->response->status(500);
        $c->stash(json => { success => 0, error => $error });
    };
    
    $c->forward('View::JSON');
}

=head2 create_result_from_table

Generate Result file from database table

=cut

sub create_result_from_table :Path('/schema-comparison/create_result_from_table') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_result_from_table',
        "Starting create_result_from_table action");
    
    # Check admin auth with fallback
    my $is_auth = 0;
    if ($c->session->{username} && $c->session->{user_id}) {
        if ($c->session->{is_admin} || (ref($c->session->{roles}) eq 'ARRAY' && grep(/admin/i, @{$c->session->{roles}})) || 
            ($c->session->{roles} && $c->session->{roles} =~ /\badmin\b/i) ||
            (ref($c->session->{user_groups}) eq 'ARRAY' && grep(/admin/i, @{$c->session->{user_groups}})) ||
            ($c->session->{user_groups} && $c->session->{user_groups} =~ /\badmin\b/i)) {
            $is_auth = 1;
        }
    } elsif ($c->user && $c->user->check_roles(qw/admin/)) {
        $is_auth = 1;
    }
    
    unless ($is_auth) {
        $c->response->status(403);
        $c->stash(json => { success => 0, error => 'Access denied' });
        $c->forward('View::JSON');
        return;
    }
    
    my $json_data;
    try {
        my $body = $c->req->body;
        if ($body) {
            local $/;
            my $json_text = <$body>;
            $json_data = decode_json($json_text);
        } else {
            die "No request body provided";
        }
    } catch {
        $c->response->status(400);
        $c->stash(json => { success => 0, error => "Invalid JSON request: $_" });
        $c->forward('View::JSON');
        return;
    };
    
    my $table_name = $json_data->{table_name};
    my $database = $json_data->{database};
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_result_from_table',
        "Received parameters - table_name: " . ($table_name || 'UNDEFINED') . 
        ", database: " . ($database || 'UNDEFINED'));
    
    unless ($table_name && $database) {
        my $error_msg = 'Missing required parameters: ';
        $error_msg .= 'table_name' unless $table_name;
        $error_msg .= ', database' unless $database;
        
        $c->response->status(400);
        $c->stash(json => { success => 0, error => $error_msg });
        $c->forward('View::JSON');
        return;
    }
    
    try {
        my $table_schema;
        if ($database eq 'ency') {
            $table_schema = $self->get_ency_table_schema($c, $table_name);
        } elsif ($database eq 'forager') {
            $table_schema = $self->get_forager_table_schema($c, $table_name);
        } else {
            die "Invalid database: $database";
        }
        
        unless ($table_schema && $table_schema->{columns}) {
            die "Could not retrieve schema for table '$table_name' from database '$database'";
        }
        
        my $result_content = $self->generate_result_file_content($table_name, $table_schema);
        my $result_file_path = $self->get_result_file_path($c, $table_name, $database);
        
        my $result_dir = dirname($result_file_path);
        unless (-d $result_dir) {
            make_path($result_dir) or die "Could not create directory '$result_dir': $!";
        }
        
        write_file($result_file_path, $result_content);
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_result_from_table',
            "Successfully created Result file '$result_file_path' for table '$table_name'");
        
        $c->stash(json => {
            success => 1,
            message => "Successfully created Result file for table '$table_name'",
            result_file_path => $result_file_path
        });
        
    } catch {
        my $error = "Error creating Result file: $_";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_result_from_table', $error);
        
        $c->response->status(500);
        $c->stash(json => { success => 0, error => $error });
    };
    
    $c->forward('View::JSON');
}

=head2 create_table_from_result

Generate database table from Result file

=cut

sub create_table_from_result :Path('/schema-comparison/create_table_from_result') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_table_from_result',
        "Starting create_table_from_result action");
    
    # Debug logging for authentication check
    my $username = $c->session->{username} || 'undefined';
    my $user_id = $c->session->{user_id} || 'undefined';
    my $is_admin_flag = $c->session->{is_admin} || 'undefined';
    my $roles = $c->session->{roles} || 'undefined';
    my $user_groups = $c->session->{user_groups} || 'undefined';
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_table_from_result',
        "Auth debug - username: $username, user_id: $user_id, is_admin: $is_admin_flag, roles: $roles, user_groups: $user_groups");
    
    # Check auth - use both session-based and Catalyst user
    my $is_auth = 0;
    if ($c->session->{username} && $c->session->{user_id}) {
        # Session-based auth
        if ($c->session->{is_admin} || (ref($c->session->{roles}) eq 'ARRAY' && grep(/admin/i, @{$c->session->{roles}})) || 
            ($c->session->{roles} && $c->session->{roles} =~ /\badmin\b/i)) {
            $is_auth = 1;
        } elsif (ref($c->session->{user_groups}) eq 'ARRAY' && grep(/admin/i, @{$c->session->{user_groups}})) {
            $is_auth = 1;
        } elsif ($c->session->{user_groups} && $c->session->{user_groups} =~ /\badmin\b/i) {
            $is_auth = 1;
        }
    }
    
    # Fallback: check Catalyst user object if available
    if (!$is_auth && $c->user) {
        $is_auth = $c->user->check_roles(qw/admin/);
    }
    
    unless ($is_auth) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_table_from_result',
            "Access denied - authentication failed. Session: username=$username, is_admin=$is_admin_flag, roles=$roles");
        $c->response->status(403);
        $c->stash(json => { success => 0, error => 'Access denied - admin role required' });
        $c->forward('View::JSON');
        return;
    }
    
    my $json_data;
    try {
        my $body = $c->req->body;
        if ($body) {
            local $/;
            my $json_text = <$body>;
            $json_data = decode_json($json_text);
        } else {
            die "No request body provided";
        }
    } catch {
        $c->response->status(400);
        $c->stash(json => { success => 0, error => "Invalid JSON request: $_" });
        $c->forward('View::JSON');
        return;
    };
    
    my $result_name = $json_data->{result_name};
    my $database = $json_data->{database};
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_table_from_result',
        "Received parameters - result_name: " . ($result_name || 'UNDEFINED') . 
        ", database: " . ($database || 'UNDEFINED'));
    
    unless ($result_name && $database) {
        my $error_msg = 'Missing required parameters: ';
        $error_msg .= 'result_name' unless $result_name;
        $error_msg .= ', database' unless $database;
        
        $c->response->status(400);
        $c->stash(json => { success => 0, error => $error_msg });
        $c->forward('View::JSON');
        return;
    }
    
    try {
        # Load the Result class dynamically
        my $namespace = $database eq 'ency' ? 'Ency' : 'Forager';
        my $class_name = "Comserv::Model::Schema::${namespace}::Result::${result_name}";
        
        # Try to require the class using eval (proper module loading)
        eval "require $class_name";
        if ($@) {
            die "Could not load Result class '$class_name': $@";
        }
        
        # Get the schema
        my $schema;
        if ($database eq 'ency') {
            $schema = $c->model('DBEncy')->schema;
        } elsif ($database eq 'forager') {
            $schema = $c->model('DBForager')->schema;
        } else {
            die "Invalid database: $database";
        }
        
        # Get a DBI database handle
        my $dbh = $schema->storage->dbh;
        
        # Get table name from the loaded Result class
        my $table_name = $class_name->table;
        unless ($table_name) {
            die "Could not retrieve table name from Result class '$class_name'";
        }
        
        # Execute a SHOW TABLES LIKE 'table_name' SQL statement to check if table exists
        my $sth = $dbh->prepare("SHOW TABLES LIKE ?");
        $sth->execute($table_name);
        my $table_exists = $sth->fetch;
        
        if (!$table_exists) {
            # The table does not exist, create it using deployment_statements
            try {
                # Get the deployment SQL statements for this specific table
                my $source = $schema->source($result_name);
                unless ($source) {
                    die "Could not find source '$result_name' in schema";
                }
                
                # Generate and execute the deployment SQL for just this table
                my @statements = $schema->deployment_statements('MySQL');
                
                # Filter to only statements that create the target table
                my @table_statements = grep { /CREATE TABLE.*\Q$table_name\E/i } @statements;
                
                if (@table_statements) {
                    foreach my $statement (@table_statements) {
                        $dbh->do($statement);
                    }
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_table_from_result',
                        "Successfully created table '$table_name' from Result class '$class_name' using SQL deployment");
                } else {
                    # Fallback: Try the full deploy if we can't isolate the statement
                    $schema->deploy();
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_table_from_result',
                        "Successfully created table '$table_name' from Result class '$class_name' using schema->deploy()");
                }
            } catch {
                my $deploy_error = $_;
                # Check if it's a permission/privilege error
                if ($deploy_error =~ /access denied|permission/i) {
                    die "Database user does not have CREATE TABLE privileges for table '$table_name': $deploy_error";
                } else {
                    die "Failed to deploy table '$table_name': $deploy_error";
                }
            };
        } else {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_table_from_result',
                "Table '$table_name' already exists, no creation needed");
        }
        
        $c->stash(json => {
            success => 1,
            message => "Successfully created table '$table_name' from Result file",
            table_name => $table_name,
            database => $database,
            result_class => $class_name,
            already_existed => !!$table_exists
        });
        
    } catch {
        my $error = "Error creating table from Result: $_";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_table_from_result', $error);
        
        $c->response->status(500);
        $c->stash(json => { success => 0, error => $error });
    };
    
    $c->forward('View::JSON');
}

=head2 get_table_field_info

Get database table field information

=cut

sub get_table_field_info {
    my ($self, $c, $table_name, $field_name, $database) = @_;
    
    my $model_name = $database eq 'ency' ? 'DBEncy' : 'DBForager';
    my $dbh = $c->model($model_name)->schema->storage->dbh;
    
    my $sth = $dbh->prepare("DESCRIBE $table_name $field_name");
    $sth->execute();
    my $row = $sth->fetchrow_hashref;
    
    if (!$row) {
        die "Field '$field_name' not found in table '$table_name'";
    }
    
    my $type = $row->{Type};
    my $data_type = $type;
    my $size;
    my $enum_list;
    
    if ($type =~ /^(\w+)\((.+)\)$/) {
        $data_type = $1;
        my $params = $2;
        if ($data_type eq 'enum' || $data_type eq 'set') {
            my @list = $params =~ /'([^']*)'/g;
            $enum_list = \@list;
        } else {
            $size = $params;
        }
    }
    
    return {
        data_type => $data_type,
        size => $size,
        is_nullable => ($row->{Null} eq 'YES' ? 1 : 0),
        is_auto_increment => ($row->{Extra} =~ /auto_increment/i ? 1 : 0),
        default_value => $row->{Default},
        enum_list => $enum_list
    };
}

=head2 get_result_field_info

Get Result file field information

=cut

sub get_result_field_info {
    my ($self, $c, $table_name, $field_name, $database) = @_;
    
    my $model_name = $database eq 'ency' ? 'DBEncy' : 'DBForager';
    my $schema = $c->model($model_name)->schema;
    
    # Find the source that matches the table name
    my $source_name;
    foreach my $s ($schema->sources) {
        my $source = $schema->source($s);
        # Some sources have 'from' as the table name, others match the class name
        if (lc($source->from) eq lc($table_name) || lc($s) eq lc($table_name)) {
            $source_name = $s;
            last;
        }
    }
    
    unless ($source_name) {
        die "Could not find DBIx::Class source for table '$table_name' in database '$database'";
    }
    
    my $source = $schema->source($source_name);
    my $info = $source->column_info($field_name);
    
    unless ($info && %$info) {
        die "Field '$field_name' not found in Result source '$source_name'";
    }
    
    return {
        data_type => $info->{data_type},
        size => $info->{size},
        is_nullable => $info->{is_nullable} ? 1 : 0,
        is_auto_increment => $info->{is_auto_increment} ? 1 : 0,
        default_value => $info->{default_value},
        enum_list => ($info->{extra} && $info->{extra}->{list}) ? $info->{extra}->{list} : undef
    };
}

=head2 update_result_field_from_table

Update Result file field from database table

=cut

sub update_result_field_from_table {
    my ($self, $c, $table_name, $field_name, $database, $table_field_info) = @_;
    
    my $result_table_mapping = $self->build_result_table_mapping($c, $database);
    my $result_file_path;
    
    my $table_key = lc($table_name);
    if (exists $result_table_mapping->{$table_key}) {
        $result_file_path = $result_table_mapping->{$table_key}->{result_path};
    }
    
    unless ($result_file_path && -f $result_file_path) {
        die "Result file not found for table '$table_name'";
    }
    
    my $content = read_file($result_file_path);
    
    my $new_field_def = "{ data_type => '$table_field_info->{data_type}'";
    if ($table_field_info->{enum_list}) {
        my $list_str = join("', '", @{$table_field_info->{enum_list}});
        $new_field_def .= ", extra => { list => ['$list_str'] }";
    }
    $new_field_def .= ", size => $table_field_info->{size}" if $table_field_info->{size};
    $new_field_def .= ", is_nullable => $table_field_info->{is_nullable}";
    $new_field_def .= ", is_auto_increment => 1" if $table_field_info->{is_auto_increment};
    if (defined $table_field_info->{default_value}) {
        my $def = $table_field_info->{default_value};
        $def =~ s/'/\\'/g;
        $new_field_def .= ", default_value => '$def'";
    }
    $new_field_def .= " }";
    
    if ($content =~ /__PACKAGE__->add_columns\(\s*(.*?)\s*\);/s) {
        my $columns_section = $1;
        
        if ($columns_section =~ /(?:^|\s|,)\s*'?$field_name'?\s*=>\s*\{[^}]+\}/) {
            $columns_section =~ s/(?:^|\s|,)\s*'?$field_name'?\s*=>\s*\{[^}]+\}/$field_name => $new_field_def/;
            $content =~ s/__PACKAGE__->add_columns\(\s*.*?\s*\);/__PACKAGE__->add_columns(\n$columns_section\n);/s;
            
            write_file($result_file_path, $content);
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_result_field_from_table',
                "Updated field '$field_name' in result file '$result_file_path'");
            
            return 1;
        }
    }
    
    die "Could not update field '$field_name' in result file";
}

=head2 update_table_field_from_result

Update database table field from Result file

=cut

sub update_table_field_from_result {
    my ($self, $c, $table_name, $field_name, $database, $result_field_info) = @_;
    
    my $data_type = $result_field_info->{data_type};
    
    # Map DBIx::Class types to MariaDB types
    if ($data_type eq 'integer') {
        $data_type = 'int';
    } elsif ($data_type eq 'text') {
        $data_type = 'longtext' if $table_name eq 'ai_messages' && ($field_name eq 'content' || $field_name eq 'metadata');
    } elsif ($data_type eq 'json') {
        $data_type = 'JSON';
    } elsif ($data_type eq 'boolean') {
        $data_type = 'tinyint(1)';
    }
    
    if ($data_type =~ /^enum$/i && $result_field_info->{enum_list}) {
        my $list_str = join("','", @{$result_field_info->{enum_list}});
        $data_type = "ENUM('$list_str')";
    } elsif ($result_field_info->{size} && $data_type !~ /\(/) {
        $data_type .= "($result_field_info->{size})";
    }
    
    my $nullable = $result_field_info->{is_nullable} ? "NULL" : "NOT NULL";
    my $default = "";
    if (defined $result_field_info->{default_value}) {
        $default = "DEFAULT '$result_field_info->{default_value}'";
    }
    
    my $extra = "";
    $extra = "AUTO_INCREMENT" if $result_field_info->{is_auto_increment};
    
    my $sql = "ALTER TABLE $table_name MODIFY COLUMN $field_name $data_type $nullable $default $extra";
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_table_field_from_result',
        "Executing SQL: $sql");
    
    try {
        my $dbh;
        if ($database eq 'ency') {
            $dbh = $c->model('DBEncy')->schema->storage->dbh;
        } elsif ($database eq 'forager') {
            $dbh = $c->model('DBForager')->schema->storage->dbh;
        } else {
            die "Invalid database: $database";
        }
        
        $dbh->do($sql);
    } catch {
        die "Error executing SQL: $_";
    };
    
    return $sql;
}

=head2 generate_result_file

Generate Result file structure (helper)

=cut

sub generate_result_file {
    my ($self, $c) = @_;
    
    my $table_name = $c->req->param('table_name');
    
    if (!$table_name) {
        $c->flash->{error_msg} = "No table name specified for Result file generation.";
        return;
    }
    
    try {
        my $db_schema = $self->get_ency_table_schema($c, $table_name);
        my $result_file_content = $self->generate_result_file_content($table_name, $db_schema);
        
        my $result_file_path = $c->path_to('lib', 'Comserv', 'Model', 'Schema', 'Ency', 'Result', ucfirst($table_name) . '.pm');
        write_file($result_file_path, $result_file_content);
        
        $c->flash->{success_msg} = "Result file generated successfully for table '$table_name'.";
        
    } catch {
        my $error = "Error generating Result file: $_";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'generate_result_file', $error);
        $c->flash->{error_msg} = $error;
    };
}

=head2 generate_result_file_content

Generate Result file Perl code content

=cut

sub generate_result_file_content {
    my ($self, $table_name, $db_schema) = @_;
    
    my $class_name = ucfirst($table_name);
    my $content = "package Comserv::Model::Schema::Ency::Result::$class_name;\n";
    $content .= "use base 'DBIx::Class::Core';\n\n";
    $content .= "__PACKAGE__->table('$table_name');\n";
    $content .= "__PACKAGE__->add_columns(\n";
    
    foreach my $column_name (sort keys %{$db_schema->{columns}}) {
        my $col = $db_schema->{columns}->{$column_name};
        my $data_type = $col->{data_type};
        my $extra_content = "";
        
        if ($data_type =~ /^enum\((.+)\)$/i) {
            my $list = $1;
            $data_type = 'enum';
            $extra_content = "        extra => { list => [$list] },\n";
        } elsif ($data_type =~ /^(\w+)\((.+)\)$/) {
            $data_type = $1;
            my $size = $2;
            $extra_content = "        size => $size,\n" unless $data_type eq 'set';
        }
        
        $content .= "    $column_name => {\n";
        $content .= "        data_type => '$data_type',\n";
        $content .= $extra_content;
        
        if ($col->{is_nullable}) {
            $content .= "        is_nullable => 1,\n";
        }
        
        if ($col->{is_auto_increment}) {
            $content .= "        is_auto_increment => 1,\n";
        }
        
        if (defined $col->{default_value}) {
            my $def = $col->{default_value};
            $def =~ s/'/\\'/g;
            $content .= "        default_value => '$def',\n";
        }
        
        $content .= "    },\n";
    }
    
    $content .= ");\n";
    
    if (@{$db_schema->{primary_keys}}) {
        my $pk_list = join(', ', map { "'$_'" } @{$db_schema->{primary_keys}});
        $content .= "__PACKAGE__->set_primary_key($pk_list);\n";
    }
    
    foreach my $constraint (@{$db_schema->{unique_constraints}}) {
        my $col_list = join(', ', map { "'$_'" } @{$constraint->{columns}});
        $content .= "__PACKAGE__->add_unique_constraint('$constraint->{name}' => [$col_list]);\n";
    }
    
    $content .= "\n1;\n";
    
    return $content;
}

=head2 build_result_table_mapping

Build mapping of table names to Result files

=cut

sub build_result_table_mapping {
    my ($self, $c, $database) = @_;
    
    my $model_name = $database eq 'ency' ? 'DBEncy' : 'DBForager';
    my $schema = $c->model($model_name)->schema;
    my %mapping = ();
    
    foreach my $source_name ($schema->sources) {
        my $source = $schema->source($source_name);
        my $table = $source->from;
        
        # Handle cases where 'from' might be a scalar ref (subquery) or other complex structure
        next if ref($table);
        
        my $class = $schema->class($source_name);
        my $rel_path = $class;
        $rel_path =~ s/::/\//g;
        $rel_path .= ".pm";
        
        # Use %INC to find the absolute path of the loaded module
        my $full_path = $INC{$rel_path};
        
        if ($full_path) {
            $mapping{lc($table)} = {
                result_name => $source_name,
                result_path => $full_path,
                last_modified => (stat($full_path))[9] || 0
            };
        }
    }
    
    return \%mapping;
}

=head2 get_ency_table_schema

Get schema info from Ency database

=cut

sub get_ency_table_schema {
    my ($self, $c, $table_name) = @_;
    
    my $schema_info = {
        columns => {},
        primary_keys => [],
        unique_constraints => [],
        foreign_keys => [],
        indexes => []
    };
    
    try {
        my $dbh = $c->model('DBEncy')->schema->storage->dbh;
        
        my $sth = $dbh->prepare("DESCRIBE $table_name");
        $sth->execute();
        
        while (my $row = $sth->fetchrow_hashref()) {
            my $column_name = $row->{Field};
            
            $schema_info->{columns}->{$column_name} = {
                data_type => $row->{Type},
                is_nullable => ($row->{Null} eq 'YES' ? 1 : 0),
                default_value => $row->{Default},
                is_auto_increment => ($row->{Extra} =~ /auto_increment/i ? 1 : 0),
                size => undef
            };
            
            if ($row->{Key} eq 'PRI') {
                push @{$schema_info->{primary_keys}}, $column_name;
            }
        }
        
        $sth = $dbh->prepare("
            SELECT 
                COLUMN_NAME,
                REFERENCED_TABLE_NAME,
                REFERENCED_COLUMN_NAME,
                CONSTRAINT_NAME
            FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE 
            WHERE TABLE_SCHEMA = DATABASE() 
            AND TABLE_NAME = ? 
            AND REFERENCED_TABLE_NAME IS NOT NULL
        ");
        $sth->execute($table_name);
        
        while (my $row = $sth->fetchrow_hashref()) {
            push @{$schema_info->{foreign_keys}}, {
                column => $row->{COLUMN_NAME},
                referenced_table => $row->{REFERENCED_TABLE_NAME},
                referenced_column => $row->{REFERENCED_COLUMN_NAME},
                constraint_name => $row->{CONSTRAINT_NAME}
            };
        }
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_ency_table_schema', 
            "Error getting ency table schema for $table_name: $_");
        die $_;
    };
    
    return $schema_info;
}

=head2 get_forager_table_schema

Get schema info from Forager database

=cut

sub get_forager_table_schema {
    my ($self, $c, $table_name) = @_;
    
    my $schema_info = {
        columns => {},
        primary_keys => [],
        unique_constraints => [],
        foreign_keys => [],
        indexes => []
    };
    
    try {
        my $dbh = $c->model('DBForager')->schema->storage->dbh;
        
        my $sth = $dbh->prepare("DESCRIBE $table_name");
        $sth->execute();
        
        while (my $row = $sth->fetchrow_hashref()) {
            my $column_name = $row->{Field};
            
            $schema_info->{columns}->{$column_name} = {
                data_type => $row->{Type},
                is_nullable => ($row->{Null} eq 'YES' ? 1 : 0),
                default_value => $row->{Default},
                is_auto_increment => ($row->{Extra} =~ /auto_increment/i ? 1 : 0),
                size => undef
            };
            
            if ($row->{Key} eq 'PRI') {
                push @{$schema_info->{primary_keys}}, $column_name;
            }
        }
        
        $sth = $dbh->prepare("
            SELECT 
                COLUMN_NAME,
                REFERENCED_TABLE_NAME,
                REFERENCED_COLUMN_NAME,
                CONSTRAINT_NAME
            FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE 
            WHERE TABLE_SCHEMA = DATABASE() 
            AND TABLE_NAME = ? 
            AND REFERENCED_TABLE_NAME IS NOT NULL
        ");
        $sth->execute($table_name);
        
        while (my $row = $sth->fetchrow_hashref()) {
            push @{$schema_info->{foreign_keys}}, {
                column => $row->{COLUMN_NAME},
                referenced_table => $row->{REFERENCED_TABLE_NAME},
                referenced_column => $row->{REFERENCED_COLUMN_NAME},
                constraint_name => $row->{CONSTRAINT_NAME}
            };
        }
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_forager_table_schema', 
            "Error getting forager table schema for $table_name: $_");
        die $_;
    };
    
    return $schema_info;
}

=head2 get_result_file_path

Get filesystem path for Result file

=cut

sub get_result_file_path {
    my ($self, $c, $table_name, $database) = @_;
    
    my $class_name = ucfirst($table_name);
    my $namespace = $database eq 'ency' ? 'Ency' : 'Forager';
    
    my $base_path = $c->path_to('lib', 'Comserv', 'Model', 'Schema', $namespace, 'Result');
    my $result_file_path = File::Spec->catfile($base_path, "$class_name.pm");
    
    return $result_file_path;
}

=head1 AUTHOR

Shanta McBain

=head1 LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

__PACKAGE__->meta->make_immutable;

1;
