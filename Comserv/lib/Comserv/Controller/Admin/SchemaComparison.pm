package Comserv::Controller::Admin::SchemaComparison;
use Moose;
use namespace::autoclean;

BEGIN { extends 'Catalyst::Controller'; }

use Try::Tiny;
use JSON qw(decode_json);
use Comserv::Util::Logging;
use Comserv::Util::AdminAuth;
use Comserv::Util::DatabaseEnv;
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

sub database_env {
    my ($self) = @_;
    return Comserv::Util::DatabaseEnv->new();
}

sub validate_database_environment {
    my ($self, $c, $database_environment, $allow_production) = @_;
    
    $allow_production //= 0;
    
    unless ($database_environment) {
        return { valid => 1, environment => $self->database_env->get_active_environment($c) };
    }
    
    unless ($self->database_env->validate_environment($database_environment)) {
        return { valid => 0, error => "Invalid database environment: $database_environment" };
    }
    
    if ($database_environment eq 'production' && !$allow_production) {
        my $metadata = $self->database_env->get_environment_metadata('production');
        return { 
            valid => 0, 
            error => "Production database modifications require explicit confirmation",
            warning_level => $metadata->{warning_level}
        };
    }
    
    return { valid => 1, environment => $database_environment };
}

=head2 sync_table_to_result

Sync database table field to Result file

=cut

sub sync_table_to_result :Path('/schema-comparison/sync_table_to_result') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'sync_table_to_result',
        "Starting sync_table_to_result action");
    
    {
        my $ok    = $self->admin_auth->check_admin_access($c, 'sync_table_to_result');
        my $roles = $c->session->{roles} || [];
        $ok ||= (ref($roles) eq 'ARRAY' && grep { lc($_) eq 'admin' } @$roles);
        $ok ||= (!ref($roles) && $roles =~ /\badmin\b/i);
        $ok ||= $c->session->{is_admin};
        unless ($ok) {
            $c->response->status(403);
            $c->stash(json => { success => 0, error => 'Access denied' });
            $c->forward('View::JSON');
            return;
        }
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
    my $database_environment = $json_data->{database_environment};
    
    unless ($table_name && $field_name && $database) {
        $c->response->status(400);
        $c->stash(json => { success => 0, error => 'Missing required parameters: table_name, field_name, database' });
        $c->forward('View::JSON');
        return;
    }
    
    my $env_validation = $self->validate_database_environment($c, $database_environment, 1);
    unless ($env_validation->{valid}) {
        $c->response->status(400);
        $c->stash(json => { 
            success => 0, 
            error => $env_validation->{error}
        });
        $c->forward('View::JSON');
        return;
    }
    
    my $active_env = $env_validation->{environment};
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'sync_table_to_result',
        "Syncing from database environment: $active_env");
    
    try {
        my $table_field_info = $self->get_table_field_info($c, $table_name, $field_name, $database);
        my $result = $self->update_result_field_from_table($c, $table_name, $field_name, $database, $table_field_info);
        
        $c->stash(json => {
            success => 1,
            message => "Successfully synced table field '$field_name' to result file (from environment: $active_env)",
            field_info => $table_field_info,
            database_environment => $active_env
        });
        
    } catch {
        my $error = "Error syncing table to result: $_";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'sync_table_to_result', $error);
        
        $c->response->status(500);
        $c->stash(json => { success => 0, error => $error });
    };
    
    $c->forward('View::JSON');
}

=head2 sync_primary_key_to_result

Sync database primary key to Result file

=cut

sub sync_primary_key_to_result :Path('/schema-comparison/sync_primary_key_to_result') :Args(0) {
    my ($self, $c) = @_;
    
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
    
    try {
        my $table_schema;
        if ($database eq 'ency') {
            $table_schema = $self->get_ency_table_schema($c, $table_name);
        } elsif ($database eq 'forager') {
            $table_schema = $self->get_forager_table_schema($c, $table_name);
        }
        
        my $pks = $table_schema->{primary_keys} || [];
        my $pk_list = join(', ', map { "'$_'" } @$pks);
        
        my $result_table_mapping = $self->build_result_table_mapping($c, $database);
        my $table_key = lc($table_name);
        my $result_file_path = $result_table_mapping->{$table_key}->{result_path};
        
        my $content = read_file($result_file_path);
        
        if ($content =~ /__PACKAGE__->set_primary_key\s*\(.*?\)\s*;/s) {
            $content =~ s/__PACKAGE__->set_primary_key\s*\(.*?\)\s*;/__PACKAGE__->set_primary_key($pk_list);/s;
        } else {
            # Add after add_columns
            if ($content =~ /(__PACKAGE__->add_columns\s*\(.*?\)\s*;)/s) {
                my $match = $1;
                $content =~ s/\Q$match\E/$match\n\n__PACKAGE__->set_primary_key($pk_list);/s;
            } else {
                die "Could not find add_columns block to insert primary key";
            }
        }
        
        write_file($result_file_path, $content);
        
        $c->stash(json => {
            success => 1,
            message => "Successfully synced primary key for table '$table_name' to result file"
        });
        
    } catch {
        $c->response->status(500);
        $c->stash(json => { success => 0, error => "Error syncing primary key: $_" });
    };
    
    $c->forward('View::JSON');
}

=head2 sync_primary_key_to_table

Sync Result file primary key to database table

=cut

sub sync_primary_key_to_table :Path('/schema-comparison/sync_primary_key_to_table') :Args(0) {
    my ($self, $c) = @_;
    
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
    
    try {
        my $result_table_mapping = $self->build_result_table_mapping($c, $database);
        my $table_key = lc($table_name);
        my $result_file_path = $result_table_mapping->{$table_key}->{result_path};
        
        my $result_schema = $self->get_result_file_schema($c, $result_file_path);
        my $pks = $result_schema->{primary_keys} || [];
        
        die "No primary keys found in Result file" unless @$pks;
        
        my $pk_list = join(', ', @$pks);
        
        my $dbh;
        if ($database eq 'ency') {
            $dbh = $c->model('DBEncy')->schema->storage->dbh;
        } elsif ($database eq 'forager') {
            $dbh = $c->model('DBForager')->schema->storage->dbh;
        }
        
        # Try to drop existing PK first, ignore error if none exists
        eval { $dbh->do("ALTER TABLE $table_name DROP PRIMARY KEY") };
        
        # Add new PK
        my $sql = "ALTER TABLE $table_name ADD PRIMARY KEY ($pk_list)";
        $dbh->do($sql);
        
        $c->stash(json => {
            success => 1,
            message => "Successfully synced primary key from result to table '$table_name'",
            sql => $sql
        });
        
    } catch {
        $c->response->status(500);
        $c->stash(json => { success => 0, error => "Error syncing primary key to table: $_" });
    };
    
    $c->forward('View::JSON');
}

=head2 sync_unique_constraint_to_table

Sync Result file unique constraint to database table

=cut

sub sync_unique_constraint_to_table :Path('/schema-comparison/sync_unique_constraint_to_table') :Args(0) {
    my ($self, $c) = @_;
    
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
    my $constraint_name = $json_data->{constraint_name};
    
    try {
        my $result_table_mapping = $self->build_result_table_mapping($c, $database);
        my $table_key = lc($table_name);
        my $result_file_path = $result_table_mapping->{$table_key}->{result_path};
        
        my $result_schema = $self->get_result_file_schema($c, $result_file_path);
        my ($constraint) = grep { ($_->{name} || 'unnamed') eq $constraint_name } @{$result_schema->{unique_constraints} || []};
        
        die "Constraint '$constraint_name' not found in Result file" unless $constraint;
        
        my $cols_list = join(', ', @{$constraint->{columns}});
        
        my $dbh;
        if ($database eq 'ency') {
            $dbh = $c->model('DBEncy')->schema->storage->dbh;
        } elsif ($database eq 'forager') {
            $dbh = $c->model('DBForager')->schema->storage->dbh;
        }
        
        # Try to drop existing index first, ignore error if none exists
        eval { $dbh->do("ALTER TABLE $table_name DROP INDEX $constraint_name") };
        
        # Add new constraint
        my $sql = "ALTER TABLE $table_name ADD CONSTRAINT $constraint_name UNIQUE ($cols_list)";
        $dbh->do($sql);
        
        $c->stash(json => {
            success => 1,
            message => "Successfully synced unique constraint '$constraint_name' from result to table",
            sql => $sql
        });
        
    } catch {
        $c->response->status(500);
        $c->stash(json => { success => 0, error => "Error syncing unique constraint to table: $_" });
    };
    
    $c->forward('View::JSON');
}

=head2 sync_unique_constraint_to_result

Sync database unique constraint to Result file

=cut

sub sync_unique_constraint_to_result :Path('/schema-comparison/sync_unique_constraint_to_result') :Args(0) {
    my ($self, $c) = @_;
    
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
    my $constraint_name = $json_data->{constraint_name};
    
    try {
        my $table_schema;
        if ($database eq 'ency') {
            $table_schema = $self->get_ency_table_schema($c, $table_name);
        } elsif ($database eq 'forager') {
            $table_schema = $self->get_forager_table_schema($c, $table_name);
        }
        
        my ($constraint) = grep { ($_->{name} || 'unnamed') eq $constraint_name } @{$table_schema->{unique_constraints} || []};
        die "Constraint '$constraint_name' not found in database" unless $constraint;
        
        my $cols_list = '[' . join(', ', map { "'$_'" } @{$constraint->{columns}}) . ']';
        my $new_call = "__PACKAGE__->add_unique_constraint('$constraint_name' => $cols_list);";
        
        my $result_table_mapping = $self->build_result_table_mapping($c, $database);
        my $table_key = lc($table_name);
        my $result_file_path = $result_table_mapping->{$table_key}->{result_path};
        
        my $content = read_file($result_file_path);
        
        if ($content =~ /__PACKAGE__->add_unique_constraint\s*\(\s*['"]\Q$constraint_name\E['"]\s*=>\s*\[.*?\]\s*\)\s*;/s) {
            $content =~ s/__PACKAGE__->add_unique_constraint\s*\(\s*['"]\Q$constraint_name\E['"]\s*=>\s*\[.*?\]\s*\)\s*;/ $new_call/s;
        } else {
            # Add after set_primary_key or add_columns
            if ($content =~ /(__PACKAGE__->set_primary_key\s*\(.*?\)\s*;)/s) {
                my $match = $1;
                $content =~ s/\Q$match\E/$match\n$new_call/s;
            } elsif ($content =~ /(__PACKAGE__->add_columns\s*\(.*?\)\s*;)/s) {
                my $match = $1;
                $content =~ s/\Q$match\E/$match\n\n$new_call/s;
            } else {
                die "Could not find insertion point for unique constraint";
            }
        }
        
        write_file($result_file_path, $content);
        
        $c->stash(json => {
            success => 1,
            message => "Successfully synced unique constraint '$constraint_name' to result file"
        });
        
    } catch {
        $c->response->status(500);
        $c->stash(json => { success => 0, error => "Error syncing unique constraint: $_" });
    };
    
    $c->forward('View::JSON');
}

=head2 sync_result_to_table

Sync Result file field to database table

=cut

sub sync_table_name_to_result :Path('/schema-comparison/sync_table_name_to_result') :Args(0) {
    my ($self, $c) = @_;
    
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
    
    try {
        my $result_table_mapping = $self->build_result_table_mapping($c, $database);
        my $table_key = lc($table_name);
        my $result_file_path = $result_table_mapping->{$table_key}->{result_path};
        
        my $content = read_file($result_file_path);
        
        if ($content =~ /__PACKAGE__->table\s*\(\s*['"]([^'"]+)['"]\s*\)\s*;/s) {
            $content =~ s/__PACKAGE__->table\s*\(\s*['"]([^'"]+)['"]\s*\)\s*;/ __PACKAGE__->table('$table_name');/s;
        } else {
            # Add before add_columns
            if ($content =~ /(__PACKAGE__->add_columns)/s) {
                $content =~ s/__PACKAGE__->add_columns/__PACKAGE__->table('$table_name');\n__PACKAGE__->add_columns/s;
            } else {
                die "Could not find add_columns block to insert table name";
            }
        }
        
        write_file($result_file_path, $content);
        
        $c->stash(json => {
            success => 1,
            message => "Successfully synced table name for '$table_name' to result file"
        });
        
    } catch {
        $c->response->status(500);
        $c->stash(json => { success => 0, error => "Error syncing table name: $_" });
    };
    
    $c->forward('View::JSON');
}

sub sync_result_to_table :Path('/schema-comparison/sync_result_to_table') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'sync_result_to_table',
        "Starting sync_result_to_table action");
    
    {
        my $ok    = $self->admin_auth->check_admin_access($c, 'sync_result_to_table');
        my $roles = $c->session->{roles} || [];
        $ok ||= (ref($roles) eq 'ARRAY' && grep { lc($_) eq 'admin' } @$roles);
        $ok ||= (!ref($roles) && $roles =~ /\badmin\b/i);
        $ok ||= $c->session->{is_admin};
        unless ($ok) {
            $c->response->status(403);
            $c->stash(json => { success => 0, error => 'Access denied' });
            $c->forward('View::JSON');
            return;
        }
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
    my $database_environment = $json_data->{database_environment};
    my $allow_production = $json_data->{allow_production} || 0;
    
    unless ($table_name && $field_name && $database) {
        $c->response->status(400);
        $c->stash(json => { success => 0, error => 'Missing required parameters: table_name, field_name, database' });
        $c->forward('View::JSON');
        return;
    }
    
    my $env_validation = $self->validate_database_environment($c, $database_environment, $allow_production);
    unless ($env_validation->{valid}) {
        $c->response->status(400);
        $c->stash(json => { 
            success => 0, 
            error => $env_validation->{error},
            warning_level => $env_validation->{warning_level}
        });
        $c->forward('View::JSON');
        return;
    }
    
    my $active_env = $env_validation->{environment};
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'sync_result_to_table',
        "Syncing to database environment: $active_env");
    
    try {
        my $result_field_info = $self->get_result_field_info($c, $table_name, $field_name, $database);
        my $sql = $self->update_table_field_from_result($c, $table_name, $field_name, $database, $result_field_info);
        
        $c->stash(json => {
            success => 1,
            message => "Successfully synced result field '$field_name' to table (environment: $active_env)",
            field_info => $result_field_info,
            sql => $sql,
            database_environment => $active_env
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
    
    {
        my $ok    = $self->admin_auth->check_admin_access($c, 'create_result_from_table');
        my $roles = $c->session->{roles} || [];
        $ok ||= (ref($roles) eq 'ARRAY' && grep { lc($_) eq 'admin' } @$roles);
        $ok ||= (!ref($roles) && $roles =~ /\badmin\b/i);
        $ok ||= $c->session->{is_admin};
        unless ($ok) {
            $c->response->status(403);
            $c->stash(json => { success => 0, error => 'Access denied' });
            $c->forward('View::JSON');
            return;
        }
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
    
    my $is_auth = $self->admin_auth->check_admin_access($c, 'create_table_from_result');
    if (!$is_auth) {
        my $roles = $c->session->{roles} || [];
        $is_auth = 1 if ref($roles) eq 'ARRAY' && grep { lc($_) eq 'admin' } @$roles;
        $is_auth = 1 if !ref($roles) && $roles =~ /\badmin\b/i;
        $is_auth = 1 if $c->session->{is_admin};
    }
    unless ($is_auth) {
        my $roles     = $c->session->{roles} || [];
        my $roles_str = ref($roles) eq 'ARRAY' ? join(',', @$roles) : ($roles // '');
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_table_from_result',
            "Access denied: username=" . ($c->session->{username} // 'UNSET')
            . " roles=$roles_str is_admin=" . ($c->session->{is_admin} // 'UNSET'));
        $c->response->status(403);
        $c->stash(json => {
            success  => 0,
            error    => 'Access denied - admin role required',
            debug    => {
                username  => $c->session->{username} // 'UNSET',
                roles     => $roles_str,
                is_admin  => $c->session->{is_admin} // 'UNSET',
                sitename  => $c->session->{SiteName} // 'UNSET',
            },
        });
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
    
    # Dereference scalar references for JSON serialization
    my $default_value = $info->{default_value};
    if (defined $default_value && ref($default_value) eq 'SCALAR') {
        $default_value = $$default_value;
    }
    
    return {
        data_type => $info->{data_type},
        size => $info->{size},
        is_nullable => $info->{is_nullable} ? 1 : 0,
        is_auto_increment => $info->{is_auto_increment} ? 1 : 0,
        default_value => $default_value,
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
    
    my $new_field_def = "{\n        data_type => '$table_field_info->{data_type}',";
    if ($table_field_info->{enum_list} && @{$table_field_info->{enum_list}}) {
        my $list_str = join("', '", @{$table_field_info->{enum_list}});
        $new_field_def .= "\n        extra => { list => ['$list_str'] },";
    }
    $new_field_def .= "\n        size => $table_field_info->{size}," if $table_field_info->{size};
    $new_field_def .= "\n        is_nullable => " . ($table_field_info->{is_nullable} ? 1 : 0) . ",";
    $new_field_def .= "\n        is_auto_increment => 1," if $table_field_info->{is_auto_increment};
    if (defined $table_field_info->{default_value}) {
        my $def = $table_field_info->{default_value};
        $def =~ s/'/\\'/g;
        $new_field_def .= "\n        default_value => '$def',";
    }
    $new_field_def .= "\n    }";
    
    if ($content =~ /(__PACKAGE__->add_columns\s*\()(.*?)(\)\s*;)/s) {
        my ($prefix, $columns_section, $suffix) = ($1, $2, $3);
        
        # Look for field name followed by => { ... }
        # We use a non-greedy match but try to catch the closing brace correctly
        # Most DBIx::Class fields end with }, or just } at the end of add_columns
        if ($columns_section =~ /(['"]?)$field_name\1\s*=>\s*\{/s) {
            # Update existing field. We match from field name until the closing brace that is followed by a comma or closing paren
            $columns_section =~ s/(['"]?)$field_name\1\s*=>\s*\{.*?\}(?=\s*(?:,|\s*$))/$field_name => $new_field_def/s;
        } else {
            # Add new field definition
            # Ensure there's a comma before if not empty
            $columns_section =~ s/\s+$//;
            if ($columns_section =~ /\S/ && $columns_section !~ /,\s*$/) {
                $columns_section .= ",";
            }
            $columns_section .= "\n    $field_name => $new_field_def,\n";
        }
        
        # Reconstruct content
        my $new_add_columns = "__PACKAGE__->add_columns($columns_section);";
        $content =~ s/__PACKAGE__->add_columns\s*\(.*?\)\s*;/$new_add_columns/s;
        
        write_file($result_file_path, $content);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_result_field_from_table',
            "Updated/Added field '$field_name' in result file '$result_file_path'");
        
        return 1;
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
        my $def_val = $result_field_info->{default_value};
        # If it's a scalar reference (like \'CURRENT_TIMESTAMP'), dereference it
        if (ref($def_val) eq 'SCALAR') {
            $def_val = $$def_val;
        }
        # Check if this is a SQL literal (CURRENT_TIMESTAMP, NOW(), etc) - these don't need quotes
        if ($def_val =~ /^(CURRENT_TIMESTAMP|NOW\(\)|CURRENT_DATE|CURRENT_TIME|NULL)$/i) {
            $default = "DEFAULT $def_val";
        } else {
            $default = "DEFAULT '$def_val'";
        }
    }
    
    my $extra = "";
    $extra = "AUTO_INCREMENT" if $result_field_info->{is_auto_increment};
    
    my $dbh;
    if ($database eq 'ency') {
        $dbh = $c->model('DBEncy')->schema->storage->dbh;
    } elsif ($database eq 'forager') {
        $dbh = $c->model('DBForager')->schema->storage->dbh;
    } else {
        die "Invalid database: $database";
    }

    # Check if column exists to determine if we should use ADD or MODIFY
    my $column_exists = 0;
    try {
        my $sth = $dbh->prepare("SHOW COLUMNS FROM $table_name LIKE ?");
        $sth->execute($field_name);
        $column_exists = 1 if $sth->fetchrow_hashref;
    } catch {
        warn "Error checking column existence: $_";
    };

    my $action = $column_exists ? "MODIFY COLUMN" : "ADD COLUMN";
    my $sql = "ALTER TABLE $table_name $action $field_name $data_type $nullable $default $extra";
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_table_field_from_result',
        "Executing SQL ($action): $sql");
    
    try {
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
    
    my %mapping = ();
    
    # Get all Result files for this database by scanning the directory
    my @result_files = $self->get_all_result_files($database);
    
    foreach my $result_file (@result_files) {
        # Extract actual table name from Result file
        my $table_name = $self->extract_table_name_from_result_file($result_file->{path});
        
        if ($table_name) {
            $mapping{lc($table_name)} = {
                result_name => $result_file->{name},
                result_path => $result_file->{path},
                last_modified => $result_file->{last_modified}
            };
        }
    }
    
    return \%mapping;
}

sub get_all_result_files {
    my ($self, $database) = @_;
    
    my @result_files = ();
    my $lib_path = dirname(dirname(dirname(dirname(__FILE__))));
    my $base_path = "$lib_path/Comserv/Model/Schema";
    
    if (lc($database) eq 'ency') {
        my $result_dir = "$base_path/Ency/Result";
        @result_files = $self->scan_result_directory_recursive($result_dir, '');
    } elsif (lc($database) eq 'forager') {
        my $result_dir = "$base_path/Forager/Result";
        @result_files = $self->scan_result_directory_recursive($result_dir, '');
    }
    
    return @result_files;
}

sub scan_result_directory_recursive {
    my ($self, $dir_path, $prefix) = @_;
    
    my @files = ();
    
    if (opendir(my $dh, $dir_path)) {
        while (my $file = readdir($dh)) {
            next if $file =~ /^\.\.?$/;
            
            my $full_path = "$dir_path/$file";
            
            if (-d $full_path) {
                push @files, $self->scan_result_directory_recursive($full_path, $prefix . $file . '/');
            } elsif ($file =~ /\.pm$/) {
                my $name = $file;
                $name =~ s/\.pm$//;
                
                push @files, {
                    name => $prefix . $name,
                    path => $full_path,
                    last_modified => (stat($full_path))[9]
                };
            }
        }
        closedir($dh);
    }
    
    return @files;
}

sub extract_table_name_from_result_file {
    my ($self, $file_path) = @_;
    
    return undef unless -f $file_path;
    
    my $content = read_file($file_path);
    
    if ($content =~ /__PACKAGE__->table\s*\(\s*['"]([^'"]+)['"]\s*\)/s) {
        return $1;
    }
    
    return undef;
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
                extra => $row->{Extra},
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
                extra => $row->{Extra},
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

=head2 get_field_comparison

AJAX endpoint to get detailed field comparison

=cut

sub get_field_comparison :Path('/schema-comparison/get_field_comparison') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_field_comparison',
        "Starting get_field_comparison action");
    
    my $table_name = $c->request->param('table_name');
    my $database = $c->request->param('database');
    
    unless ($table_name && $database) {
        $c->response->status(400);
        $c->stash(json => {
            success => 0,
            error => 'Missing table_name or database parameter'
        });
        $c->forward('View::JSON');
        return;
    }
    
    try {
        # Build comprehensive mapping for this database
        my $result_table_mapping = $self->build_result_table_mapping($c, $database);
        
        my $comparison = $self->get_table_result_comparison_v2($c, $table_name, $database, $result_table_mapping);
        
        $c->stash(json => {
            success => 1,
            comparison => $comparison,
            debug_mode => $c->session->{debug_mode} ? 1 : 0
        });
        
    } catch {
        my $error = "Error getting field comparison for $table_name ($database): $_";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_field_comparison', $error);
        
        $c->response->status(500);
        $c->stash(json => {
            success => 0,
            error => $error
        });
    };
    
    $c->forward('View::JSON');
}

=head2 get_table_result_comparison_v2

Compare table and result file schemas (v2)

=cut

sub get_table_result_comparison_v2 {
    my ($self, $c, $table_name, $database, $result_table_mapping) = @_;
    
    # Get table schema
    my $table_schema;
    eval {
        if ($database eq 'ency') {
            $table_schema = $self->get_ency_table_schema($c, $table_name);
        } elsif ($database eq 'forager') {
            $table_schema = $self->get_forager_table_schema($c, $table_name);
        } else {
            die "Invalid database: $database";
        }
    };
    if ($@) {
        warn "Failed to get table schema for $table_name ($database): $@";
        $table_schema = { columns => {} };
    }
    
    # Check if this table has a corresponding result file using the mapping
    my $table_key = lc($table_name);
    my $result_info = $result_table_mapping->{$table_key};
    my $result_schema = { columns => {} };
    
    if ($result_info && -f $result_info->{result_path}) {
        eval {
            $result_schema = $self->get_result_file_schema($c, $result_info->{result_path});
        };
        if ($@) {
            warn "Failed to parse Result file $result_info->{result_path}: $@";
            $result_schema = { columns => {} };
        }
    }
    
    # Create field comparison
    my $comparison = {
        table_name => $table_name,
        database => $database,
        has_result_file => $result_info ? 1 : 0,
        result_file_path => $result_info ? $result_info->{result_path} : undef,
        package_table => $result_schema->{table_name},
        fields => {},
        primary_keys => {
            table => $table_schema->{primary_keys} || [],
            result => $result_schema->{primary_keys} || []
        },
        unique_constraints => {
            table => $table_schema->{unique_constraints} || [],
            result => $result_schema->{unique_constraints} || []
        },
        relationships => $result_schema->{relationships} || {},
        raw_package_calls => $result_schema->{raw_package_calls} || []
    };
    
    # Get all unique field names from both sources
    my %all_fields = ();
    if ($table_schema && $table_schema->{columns}) {
        %all_fields = (%all_fields, map { $_ => 1 } keys %{$table_schema->{columns}});
    }
    if ($result_schema && $result_schema->{columns}) {
        %all_fields = (%all_fields, map { $_ => 1 } keys %{$result_schema->{columns}});
    }
    
    # Compare each field
    foreach my $field_name (sort keys %all_fields) {
        my $table_field = $table_schema->{columns}->{$field_name};
        my $result_field = $result_schema->{columns}->{$field_name};
        
        # Add primary key and foreign key status to field data
        if ($table_field) {
            $table_field->{is_primary_key} = (grep { $_ eq $field_name } @{$table_schema->{primary_keys} || []}) ? 1 : 0;
            $table_field->{is_foreign_key} = (grep { $_->{column} eq $field_name } @{$table_schema->{foreign_keys} || []}) ? 1 : 0;
        }
        if ($result_field) {
            $result_field->{is_primary_key} = (grep { $_ eq $field_name } @{$result_schema->{primary_keys} || []}) ? 1 : 0;
            unless ($result_field->{is_foreign_key}) {
                $result_field->{is_foreign_key} = (grep { ($_->{column} || '') eq $field_name } values %{$result_schema->{relationships} || {}}) ? 1 : 0;
            }
        }
        
        # Clean scalar references from result field for JSON serialization
        my $cleaned_result_field = $result_field ? $self->clean_scalar_refs($result_field) : undef;
        
        $comparison->{fields}->{$field_name} = {
            table => $table_field,
            result => $cleaned_result_field,
            differences => $self->compare_field_attributes($table_field, $result_field, $c, $field_name)
        };
    }
    
    # Add high-level differences for __PACKAGE__ attributes
    $comparison->{differences} = $self->find_schema_differences($table_schema, $result_schema, $table_name);
    
    return $comparison;
}

=head2 find_schema_differences

Find high-level differences including PK and Unique constraints

=cut

sub find_schema_differences {
    my ($self, $db_schema, $result_schema, $actual_table_name) = @_;
    
    my @differences = ();
    
    # Compare __PACKAGE__->table
    if ($result_schema->{table_name} && $actual_table_name && $result_schema->{table_name} ne $actual_table_name) {
        push @differences, {
            type => 'table_name_mismatch',
            attribute => 'table',
            table_value => $actual_table_name,
            result_value => $result_schema->{table_name},
            description => "Table name mismatch in __PACKAGE__->table"
        };
    }
    
    # Column presence/absence differences are already handled by get_table_result_comparison_v2
    # but we can add them here for a summary
    
    # Compare Primary Keys
    my @db_pks = sort @{$db_schema->{primary_keys} || []};
    my @result_pks = sort @{$result_schema->{primary_keys} || []};
    
    if (join(',', @db_pks) ne join(',', @result_pks)) {
        push @differences, {
            type => 'primary_key_mismatch',
            attribute => 'set_primary_key',
            table_value => join(', ', @db_pks) || 'None',
            result_value => join(', ', @result_pks) || 'None',
            description => "Primary key mismatch"
        };
    }
    
    # Compare Unique Constraints
    # This is more complex because they have names
    my %db_uniques = map { ($_->{name} || 'unnamed') => join(',', sort @{$_->{columns}}) } @{$db_schema->{unique_constraints} || []};
    my %result_uniques = map { ($_->{name} || 'unnamed') => join(',', sort @{$_->{columns}}) } @{$result_schema->{unique_constraints} || []};
    
    foreach my $name (keys %db_uniques) {
        if (!exists $result_uniques{$name}) {
            push @differences, {
                type => 'unique_constraint_missing_in_result',
                attribute => "add_unique_constraint ($name)",
                table_value => $db_uniques{$name},
                result_value => undef,
                description => "Unique constraint '$name' missing in Result file"
            };
        } elsif ($db_uniques{$name} ne $result_uniques{$name}) {
            push @differences, {
                type => 'unique_constraint_mismatch',
                attribute => "add_unique_constraint ($name)",
                table_value => $db_uniques{$name},
                result_value => $result_uniques{$name},
                description => "Unique constraint '$name' column mismatch"
            };
        }
    }
    
    foreach my $name (keys %result_uniques) {
        if (!exists $db_uniques{$name}) {
            push @differences, {
                type => 'unique_constraint_missing_in_table',
                attribute => "add_unique_constraint ($name)",
                table_value => undef,
                result_value => $result_uniques{$name},
                description => "Unique constraint '$name' exists in Result file but not in database"
            };
        }
    }
    
    return \@differences;
}

sub compare_field_attributes {
    my ($self, $table_field, $result_field, $c, $field_name) = @_;
    
    my @differences = ();
    my @attributes = qw(data_type size is_nullable is_auto_increment is_primary_key is_foreign_key default_value extra);
    
    foreach my $attr (@attributes) {
        my $table_value = $table_field ? $table_field->{$attr} : undef;
        my $result_value = $result_field ? $result_field->{$attr} : undef;
        
        my $orig_table = $table_value;
        my $orig_result = $result_value;
        
        $table_value = $self->normalize_field_value($attr, $table_value);
        $result_value = $self->normalize_field_value($attr, $result_value);
        
        if (defined $table_value && defined $result_value) {
            if ($table_value ne $result_value) {
                push @differences, {
                    attribute => $attr,
                    table_value => $table_value,
                    result_value => $result_value,
                    original_table_value => $orig_table,
                    original_result_value => $orig_result,
                    type => 'different'
                };
            }
        } elsif (defined $table_value && !defined $result_value) {
            push @differences, {
                attribute => $attr,
                table_value => $table_value,
                result_value => undef,
                type => 'missing_in_result'
            };
        } elsif (!defined $table_value && defined $result_value) {
            push @differences, {
                attribute => $attr,
                table_value => undef,
                result_value => $result_value,
                type => 'missing_in_table'
            };
        }
    }
    
    return \@differences;
}

sub normalize_field_value {
    my ($self, $attribute, $value) = @_;
    return undef unless defined $value;
    
    if ($attribute eq 'data_type') {
        return $self->normalize_data_type($value);
    }
    if ($attribute =~ /^is_/) {
        return $value ? 1 : 0;
    }
    if ($attribute eq 'size') {
        return "$value" if $value =~ /^[\d,]+$/;
    }
    return "$value";
}

sub normalize_data_type {
    my ($self, $data_type) = @_;
    return '' unless defined $data_type;
    $data_type = lc($data_type);
    $data_type =~ s/\([^)]*\)//g;
    $data_type =~ s/^\s+|\s+$//g;
    $data_type =~ s/\s+(unsigned|signed|zerofill|binary)//g;
    
    my %mapping = (
        'int' => 'integer', 'int4' => 'integer', 'integer' => 'integer',
        'varchar' => 'varchar', 'text' => 'text', 'longtext' => 'text',
        'tinyint' => 'boolean', 'bool' => 'boolean', 'boolean' => 'boolean',
        'datetime' => 'datetime', 'timestamp' => 'timestamp', 'json' => 'json'
    );
    return $mapping{$data_type} || $data_type;
}

sub get_result_file_schema {
    my ($self, $c, $file_path) = @_;
    
    my $schema_info = {
        file_path => $file_path,
        columns => {},
        primary_keys => [],
        unique_constraints => [],
        relationships => {},
        table_name => undef,
        raw_package_calls => []
    };
    
    try {
        my $content = read_file($file_path);
        
        if ($content =~ /__PACKAGE__->table\s*\(\s*['"]([^'"]+)['"]\s*\)/s) {
            $schema_info->{table_name} = $1;
        }
        
        while ($content =~ /(__PACKAGE__->(\w+)\s*\((.*?)\)\s*;)/gs) {
            push @{$schema_info->{raw_package_calls}}, {
                full => $1, method => $2, args => $3
            };
        }
        
        if ($content =~ /__PACKAGE__->add_columns\s*\((.*?)\);/s) {
            $schema_info->{columns} = $self->parse_result_file_columns($1);
        }
        
        if ($content =~ /__PACKAGE__->set_primary_key\s*\((.*?)\)/s) {
            my $pk_text = $1;
            $pk_text =~ s/['"\s]//g;
            @{$schema_info->{primary_keys}} = split(/,/, $pk_text);
        }
        
        while ($content =~ /__PACKAGE__->add_unique_constraint\s*\(\s*(?:['"]([^'"]+)['"]\s*=>\s*)?\[(.*?)\]\s*\)/gs) {
            my $name = $1 || 'unnamed';
            my $cols = $2;
            $cols =~ s/['"\s]//g;
            push @{$schema_info->{unique_constraints}}, {
                name => $name, columns => [split(/,/, $cols)]
            };
        }
        
        while ($content =~ /__PACKAGE__->(belongs_to|has_many|has_one|might_have)\s*\(\s*['"]?(\w+)['"]?\s*=>\s*['"]?([^'",\s\)]+)['"]?\s*(?:,\s*(?:['"]?(\w+)['"]?|\{(.*?)\}))?/gs) {
            my ($type, $accessor, $class, $fk) = ($1, $2, $3, $4);
            $schema_info->{relationships}->{$accessor} = {
                type => $type, class => $class, column => $fk || $accessor
            };
        }
    } catch {
        warn "Error parsing Result file $file_path: $_";
    };
    
    return $schema_info;
}

sub parse_result_file_columns {
    my ($self, $text) = @_;
    my $columns = {};
    while ($text =~ /(\w+)\s*=>\s*\{([\s\S]*?)\}(?=\s*,\s*\w+\s*=>|\s*,\s*$|\s*\))/g) {
        my ($name, $def) = ($1, $2);
        my $info = {};
        while ($def =~ /(\w+)\s*=>\s*(?:['"]([^'"]+)['"]|(\d+)|\\['"]([^'"]+)['"]|\{([\s\S]*?)\})/g) {
            my $attr = $1;
            my $val = $2 // $3 // $4 // $5;
            # If the value was captured from \'...' syntax, mark it as a scalar ref
            if (defined $4) {
                # This was \'SOMETHING', which is a scalar reference in Perl
                # Store the actual string value
                $info->{$attr} = $val;
            } else {
                $info->{$attr} = $val;
            }
        }
        $columns->{$name} = $info;
    }
    return $columns;
}

=head2 clean_scalar_refs

Recursively clean scalar references from data structures for JSON serialization

=cut

sub clean_scalar_refs {
    my ($self, $data) = @_;
    
    return undef unless defined $data;
    
    # If it's a scalar reference, dereference it
    if (ref($data) eq 'SCALAR') {
        return $$data;
    }
    
    # If it's a hash, recursively clean all values
    if (ref($data) eq 'HASH') {
        my $cleaned = {};
        foreach my $key (keys %$data) {
            $cleaned->{$key} = $self->clean_scalar_refs($data->{$key});
        }
        return $cleaned;
    }
    
    # If it's an array, recursively clean all elements
    if (ref($data) eq 'ARRAY') {
        return [ map { $self->clean_scalar_refs($_) } @$data ];
    }
    
    # Otherwise return as-is
    return $data;
}

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
