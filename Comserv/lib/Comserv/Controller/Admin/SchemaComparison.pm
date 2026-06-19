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

sub begin :Private {
    my ($self, $c) = @_;

    my $username = $c->session->{username} // '';
    my $roles    = $c->session->{roles}    || [];
    my @role_list = ref($roles) eq 'ARRAY' ? @$roles : split /,/, $roles;
    my $has_admin = grep { lc($_) eq 'admin' } @role_list;

    return 1 if $has_admin;
    return 1 if $username && $username ne 'Guest';

    my $is_ajax = ($c->req->header('X-Requested-With') // '') eq 'XMLHttpRequest'
               || ($c->req->content_type // '') =~ m{application/json}i;

    if ($is_ajax || $c->req->method ne 'GET') {
        $c->response->status(401);
        $c->stash(json => { success => 0, error => 'Not authenticated. Please log in first.' });
        $c->forward('View::JSON');
        $c->detach;
        return;
    }

    $c->flash->{error_msg} = 'Please log in as an administrator to access schema comparison.';
    $c->res->redirect($c->uri_for('/user/login', { destination => $c->req->uri }));
    $c->detach;
}

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

sub _write_result_file_safe {
    my ($self, $result_file_path, $content) = @_;
    my $tmpfile = $result_file_path . '.syntaxcheck.tmp';
    write_file($tmpfile, $content);
    my $check = `perl -c "$tmpfile" 2>&1`;
    unlink $tmpfile;
    unless ($check =~ /syntax OK/) {
        die "Generated code failed Perl syntax check — file NOT written.\n"
          . "Error: $check";
    }
    write_file($result_file_path, $content);
    return 1;
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
        
        $self->_write_result_file_safe($result_file_path, $content);
        
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
        
        # Match by name first; for 'unnamed' also match by column set (MySQL auto-naming)
        my ($constraint) = grep { ($_->{name} || 'unnamed') eq $constraint_name } @{$table_schema->{unique_constraints} || []};
        unless ($constraint && $constraint_name eq 'unnamed') {
            # Also try column-based match when constraint_name is 'unnamed'
            if ($constraint_name eq 'unnamed') {
                ($constraint) = @{$table_schema->{unique_constraints} || []};
            }
        }
        die "Constraint '$constraint_name' not found in database" unless $constraint;
        
        my $cols_list = '[' . join(', ', map { "'$_'" } @{$constraint->{columns}}) . ']';
        # Use unnamed format (no name) when constraint_name is 'unnamed' or matches a column name
        my $is_unnamed = ($constraint_name eq 'unnamed')
            || (grep { $_ eq $constraint_name } @{$constraint->{columns}});
        my $new_call = $is_unnamed
            ? "__PACKAGE__->add_unique_constraint($cols_list);"
            : "__PACKAGE__->add_unique_constraint('$constraint_name' => $cols_list);";
        
        my $result_table_mapping = $self->build_result_table_mapping($c, $database);
        my $table_key = lc($table_name);
        my $result_file_path = $result_table_mapping->{$table_key}->{result_path};
        
        my $content = read_file($result_file_path);
        
        # Try to replace existing: named format
        if (!$is_unnamed && $content =~ /__PACKAGE__->add_unique_constraint\s*\(\s*['"]\Q$constraint_name\E['"]\s*=>\s*\[.*?\]\s*\)\s*;/s) {
            $content =~ s/__PACKAGE__->add_unique_constraint\s*\(\s*['"]\Q$constraint_name\E['"]\s*=>\s*\[.*?\]\s*\)\s*;/$new_call/s;
        # Try to replace existing: unnamed format (no name argument)
        } elsif ($is_unnamed && $content =~ /__PACKAGE__->add_unique_constraint\s*\(\s*\[.*?\]\s*\)\s*;/s) {
            $content =~ s/__PACKAGE__->add_unique_constraint\s*\(\s*\[.*?\]\s*\)\s*;/$new_call/s;
        } else {
            # Insert after set_primary_key or add_columns
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
        
        $self->_write_result_file_safe($result_file_path, $content);
        
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
        
        $self->_write_result_file_safe($result_file_path, $content);
        
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
        
        $self->_write_result_file_safe($result_file_path, $result_content);
        
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
    
    my $result_name   = $json_data->{result_name};
    my $database      = $json_data->{database};
    my $force_recreate = $json_data->{force_recreate} ? 1 : 0;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_table_from_result',
        "Received parameters - result_name: " . ($result_name || 'UNDEFINED') .
        ", database: " . ($database || 'UNDEFINED') .
        ", force_recreate: $force_recreate");

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
        # result_name may contain '/' from scan_result_directory_recursive (subdir prefix);
        # convert to '::' so the eval'd require is valid Perl
        my $namespace  = $database eq 'ency' ? 'Ency' : 'Forager';
        (my $result_path = $result_name) =~ s{/}{::}g;
        my $class_name = "Comserv::Model::Schema::${namespace}::Result::${result_path}";

        eval "require $class_name";
        if ($@) {
            die "Could not load Result class '$class_name': $@";
        }

        # Get the schema / DBH
        my $schema;
        if ($database eq 'ency') {
            $schema = $c->model('DBEncy')->schema;
        } elsif ($database eq 'forager') {
            $schema = $c->model('DBForager')->schema;
        } else {
            die "Invalid database: $database";
        }

        my $dbh = $schema->storage->dbh;

        # Get table name from the loaded Result class
        my $table_name = $class_name->table;
        unless ($table_name) {
            die "Could not retrieve table name from Result class '$class_name'";
        }

        # Check if table exists
        my $sth = $dbh->prepare("SHOW TABLES LIKE ?");
        $sth->execute($table_name);
        my $table_exists = $sth->fetch;

        # Handle force_recreate: drop the table if it exists but is empty
        if ($table_exists && $force_recreate) {
            my ($row_count) = $dbh->selectrow_array("SELECT COUNT(*) FROM `$table_name`");
            if ($row_count > 0) {
                die "Cannot force-recreate table '$table_name' — it contains $row_count rows. "
                  . "Delete all rows first, or use the per-field sync buttons instead.";
            }
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_table_from_result',
                "force_recreate: dropping empty table '$table_name'");
            $dbh->do("SET FOREIGN_KEY_CHECKS=0");
            $dbh->do("DROP TABLE `$table_name`");
            $dbh->do("SET FOREIGN_KEY_CHECKS=1");
            $table_exists = undef;  # proceed to creation below
        }

        if (!$table_exists) {
            # Create the table using deployment_statements
            try {
                my $source = $schema->source($result_path);
                unless ($source) {
                    die "Could not find source '$result_path' in schema";
                }

                my @statements = $schema->deployment_statements('MySQL');
                my @table_statements = grep { /CREATE TABLE\s+`?\Q$table_name\E`?/i } @statements;

                if (@table_statements) {
                    $dbh->do('SET FOREIGN_KEY_CHECKS=0');
                    foreach my $statement (@table_statements) {
                        ($statement) = ($statement =~ /(CREATE\s+TABLE\b.*)/si);
                        next unless $statement;
                        my $safe_statement = _strip_fk_constraints($statement);
                        $dbh->do($safe_statement);
                    }
                    $dbh->do('SET FOREIGN_KEY_CHECKS=1');
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_table_from_result',
                        "Successfully created table '$table_name' from Result class '$class_name'");
                } else {
                    $dbh->do('SET FOREIGN_KEY_CHECKS=0');
                    $schema->deploy();
                    $dbh->do('SET FOREIGN_KEY_CHECKS=1');
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_table_from_result',
                        "Deployed table '$table_name' via schema->deploy()");
                }
            } catch {
                my $deploy_error = $_;
                eval { $dbh->do('SET FOREIGN_KEY_CHECKS=1') };
                if ($deploy_error =~ /access denied|permission/i) {
                    die "Database user lacks CREATE TABLE privilege for '$table_name': $deploy_error";
                } else {
                    die "Failed to deploy table '$table_name': $deploy_error";
                }
            };
        } else {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_table_from_result',
                "Table '$table_name' already exists — use force_recreate:true (only if empty) to replace it");
        }

        $c->stash(json => {
            success      => 1,
            message      => "Successfully created table '$table_name' from Result file",
            table_name   => $table_name,
            database     => $database,
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

=head2 remove_field_from_result

Remove a field definition from a Result file

=cut

sub remove_field_from_result :Path('/schema-comparison/remove_field_from_result') :Args(0) {
    my ($self, $c) = @_;

    my $json_data;
    try {
        local $/;
        my $body = $c->req->body;
        $json_data = decode_json(<$body>) if $body;
    } catch {
        $c->response->status(400);
        $c->stash(json => { success => 0, error => "Invalid JSON: $_" });
        $c->forward('View::JSON');
        return;
    };

    my $table_name = $json_data->{table_name};
    my $field_name  = $json_data->{field_name};
    my $database    = $json_data->{database};

    unless ($table_name && $field_name && $database) {
        $c->response->status(400);
        $c->stash(json => { success => 0, error => 'Missing required parameters: table_name, field_name, database' });
        $c->forward('View::JSON');
        return;
    }

    try {
        my $result_table_mapping = $self->build_result_table_mapping($c, $database);
        my $result_file_path = $result_table_mapping->{lc($table_name)}->{result_path};

        die "Result file not found for table '$table_name'" unless $result_file_path && -f $result_file_path;

        my $content = read_file($result_file_path);

        # Make a backup first
        write_file("$result_file_path.bak", $content);

        # Remove the field from add_columns block using balanced-brace extraction
        if ($content =~ /(__PACKAGE__->add_columns\s*\()(.*?)(\s*\)\s*;)/s) {
            my ($prefix, $cols, $suffix) = ($1, $2, $3);
            my $original_cols = $cols;

            # Find and remove: optional comma before, fieldname => { ... }, trailing comma/whitespace
            # Pattern: optional leading comma+whitespace, fieldname => {balanced}, optional trailing comma
            my $found = 0;
            my $new_cols = '';
            my $pos = 0;
            while ($cols =~ /\b(\w+)\s*=>\s*\{/g) {
                my $fname = $1;
                my $fstart = pos($cols) - length($fname) - length(' => {') + 1;
                my $brace_start = pos($cols);
                my $depth = 1;
                my $i = $brace_start;
                while ($i < length($cols) && $depth > 0) {
                    my $ch = substr($cols, $i, 1);
                    $depth++ if $ch eq '{';
                    $depth-- if $ch eq '}';
                    $i++;
                }
                # $i is now one past the closing '}'
                if ($fname eq $field_name) {
                    # Remove this field: capture text before and after
                    my $before = substr($cols, 0, $fstart);
                    my $after  = substr($cols, $i);
                    # Strip trailing comma from $before or leading comma from $after
                    $before =~ s/,\s*$//s;
                    $after  =~ s/^\s*,//s;
                    $cols = $before . $after;
                    $found = 1;
                    last;
                }
                pos($cols) = $i;
            }

            die "Field '$field_name' not found in Result file add_columns" unless $found;

            my $new_content = $prefix . $cols . $suffix;
            $content =~ s/__PACKAGE__->add_columns\s*\(.*?\)\s*;/$new_content/s;
            $self->_write_result_file_safe($result_file_path, $content);

            $c->stash(json => {
                success => 1,
                message => "Field '$field_name' removed from Result file (backup at $result_file_path.bak)"
            });
        } else {
            die "Could not parse add_columns block in Result file";
        }
    } catch {
        $c->response->status(500);
        $c->stash(json => { success => 0, error => "Error removing field from Result: $_" });
    };

    $c->forward('View::JSON');
}

=head2 remove_field_from_table

Drop a column from the database table (ALTER TABLE DROP COLUMN)

=cut

sub remove_field_from_table :Path('/schema-comparison/remove_field_from_table') :Args(0) {
    my ($self, $c) = @_;

    my $json_data;
    try {
        local $/;
        my $body = $c->req->body;
        $json_data = decode_json(<$body>) if $body;
    } catch {
        $c->response->status(400);
        $c->stash(json => { success => 0, error => "Invalid JSON: $_" });
        $c->forward('View::JSON');
        return;
    };

    my $table_name  = $json_data->{table_name};
    my $field_name  = $json_data->{field_name};
    my $database    = $json_data->{database};
    my $confirmed   = $json_data->{confirmed};

    unless ($table_name && $field_name && $database) {
        $c->response->status(400);
        $c->stash(json => { success => 0, error => 'Missing required parameters: table_name, field_name, database' });
        $c->forward('View::JSON');
        return;
    }

    unless ($confirmed) {
        $c->response->status(400);
        $c->stash(json => { success => 0, error => 'Confirmation required to drop a column' });
        $c->forward('View::JSON');
        return;
    }

    try {
        my $model_name = $database eq 'ency' ? 'DBEncy' : 'DBForager';
        my $dbh = $c->model($model_name)->schema->storage->dbh;

        my $sql = "ALTER TABLE `$table_name` DROP COLUMN `$field_name`";
        $dbh->do($sql);

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'remove_field_from_table',
            "Dropped column '$field_name' from table '$table_name' in $database: $sql");

        $c->stash(json => {
            success => 1,
            message => "Column '$field_name' dropped from table '$table_name'",
            sql => $sql
        });
    } catch {
        $c->response->status(500);
        $c->stash(json => { success => 0, error => "Error dropping column: $_" });
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
        # Must match at start-of-line/after comma (not inside string values)
        # Use (?:^|,)\s* anchor to avoid matching field names inside comment/string values
        if ($columns_section =~ /(?:^|,)\s*(['"]?)$field_name\1\s*=>\s*\{/ms) {
            # Update existing field — anchored to start of field definition
            $columns_section =~ s/(?:^|(?<=,))\s*(['"]?)$field_name\1\s*=>\s*\{.*?\}(?=\s*(?:,|\s*\z))/\n    $field_name => $new_field_def/ms;
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
        my $new_content = $content;
        $new_content =~ s/__PACKAGE__->add_columns\s*\(.*?\)\s*;/$new_add_columns/s;

        $self->_write_result_file_safe($result_file_path, $new_content);
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
        $self->_write_result_file_safe($result_file_path, $result_file_content);
        
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
    
    my $class_name = _table_to_class_name($table_name);
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
        # If the index name matches a column name, MySQL auto-named it - use unnamed format
        my $is_auto_named = grep { $_ eq $constraint->{name} } @{$constraint->{columns}};
        if ($is_auto_named || !$constraint->{name} || $constraint->{name} eq 'unnamed') {
            $content .= "__PACKAGE__->add_unique_constraint([$col_list]);\n";
        } else {
            $content .= "__PACKAGE__->add_unique_constraint('$constraint->{name}' => [$col_list]);\n";
        }
    }
    
    $content .= "\n1;\n";
    
    return $content;
}

=head2 build_result_table_mapping

Build mapping of table names to Result files

=cut

sub build_result_table_mapping {
    my ($self, $c, $database) = @_;
    # Delegated to single Parser impl (consolidation after refactor, uses fixed robust discovery)
    return Comserv::Util::Schema::ResultParser->new->build_result_table_mapping($database, $c || $self);
}

sub get_all_result_files {
    my ($self, $database, $c) = @_;
    # Delegated to single canonical impl (fixes path bug and ensures all display paths use same Result discovery)
    my $ctx = (ref($c) && $c->can('path_to')) ? $c : undef;
    return Comserv::Util::Schema::ResultParser->new->get_all_result_files($database, $ctx);
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
    # Delegated (consolidation)
    return Comserv::Util::Schema::ResultParser->new->extract_table_name_from_result_file($file_path);
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

        my $idx_sth = $dbh->prepare("SHOW INDEX FROM `$table_name` WHERE Non_unique = 0 AND Key_name != 'PRIMARY'");
        $idx_sth->execute();
        my %unique_idx_seq;
        while (my $row = $idx_sth->fetchrow_hashref()) {
            $unique_idx_seq{$row->{Key_name}}{$row->{Seq_in_index}} = $row->{Column_name};
        }
        foreach my $idx_name (sort keys %unique_idx_seq) {
            my @cols = map { $unique_idx_seq{$idx_name}{$_} } sort { $a <=> $b } keys %{$unique_idx_seq{$idx_name}};
            push @{$schema_info->{unique_constraints}}, {
                name => $idx_name,
                columns => \@cols
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

        my $idx_sth = $dbh->prepare("SHOW INDEX FROM `$table_name` WHERE Non_unique = 0 AND Key_name != 'PRIMARY'");
        $idx_sth->execute();
        my %unique_idx_seq;
        while (my $row = $idx_sth->fetchrow_hashref()) {
            $unique_idx_seq{$row->{Key_name}}{$row->{Seq_in_index}} = $row->{Column_name};
        }
        foreach my $idx_name (sort keys %unique_idx_seq) {
            my @cols = map { $unique_idx_seq{$idx_name}{$_} } sort { $a <=> $b } keys %{$unique_idx_seq{$idx_name}};
            push @{$schema_info->{unique_constraints}}, {
                name => $idx_name,
                columns => \@cols
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
        result_name => $result_info ? $result_info->{result_name} : undef,
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
            # Default common omitted attributes in Result definitions so UI display
            # and diff detection are consistent with DB side and our normalize rules.
            # (Result files conventionally omit is_nullable etc for non-null columns.)
            $result_field->{is_nullable} //= 0;
            $result_field->{is_auto_increment} //= 0;
            $result_field->{default_value} //= undef;
            $result_field->{extra} = defined $result_field->{extra} ? "$result_field->{extra}" : '';
            if (defined $result_field->{size}) {
                $result_field->{size} = 0 + $result_field->{size};
            }
        }
        
        # Also ensure table side has clean values (DB always populates, but be defensive)
        if ($table_field) {
            $table_field->{is_nullable} //= 0;
            $table_field->{is_auto_increment} //= 0;
            $table_field->{default_value} //= undef;
            $table_field->{extra} = defined $table_field->{extra} ? "$table_field->{extra}" : '';
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
    
    # Ensure column presence missing_in_database are in differences (for client JS merge from differences, and summary)
    # (find_schema_differences doesn't add per-column presence, only PK/uniques)
    my %db_cols  = map { $_ => 1 } keys %{ $table_schema->{columns} || {} };
    my %res_cols = %{ $result_schema->{columns} || {} };
    foreach my $col (keys %res_cols) {
        unless (exists $db_cols{$col}) {
            push @{ $comparison->{differences} }, {
                type             => 'missing_in_database',
                column           => $col,
                description      => "Column '$col' exists in Result file but not in database",
                result_definition => $res_cols{$col},
            };
        }
    }
    
    # Safety net: guarantee that every Result-only field appears in fields (so admin UI can offer "add to table")
    # Explicitly merge any result columns not in table (defensive after refactor)
    if ($result_schema && $result_schema->{columns}) {
        foreach my $fn (keys %{$result_schema->{columns}}) {
            if (!exists $comparison->{fields}{$fn} || !$comparison->{fields}{$fn}{result}) {
                my $rf = $result_schema->{columns}{$fn};
                $comparison->{fields}{$fn} ||= { table => undef, result => undef, differences => [] };
                $comparison->{fields}{$fn}{result} = $self->clean_scalar_refs($rf);
                # mark as needs add
                $comparison->{fields}{$fn}{table} = undef;
            }
        }
    }
    if ($comparison->{differences}) {
        foreach my $d (@{ $comparison->{differences} }) {
            next unless ($d->{type} || '') eq 'missing_in_database';
            my $fn = $d->{column};
            next unless $fn;
            $comparison->{fields}{$fn} ||= {
                table => undef,
                result => undef,
                differences => []
            };
            if ($d->{result_definition} && !$comparison->{fields}{$fn}{result}) {
                $comparison->{fields}{$fn}{result} = $self->clean_scalar_refs($d->{result_definition});
            }
            if (!@{ $comparison->{fields}{$fn}{differences} || [] }) {
                push @{ $comparison->{fields}{$fn}{differences} }, {
                    type => 'missing_in_table',
                    attribute => 'existence',
                    table_value => undef,
                    result_value => 'present'
                };
            }
        }
    }
    
    # Provide result_file_schema for client-side safety merge in JS (displayFields from result_file_schema.columns)
    $comparison->{result_file_schema} = $result_schema;
    
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
    # DB constraints use MySQL index names; Result file unnamed constraints use 'unnamed' key.
    # We match by name first, then fall back to column-set matching for 'unnamed' Result constraints.
    my %db_uniques     = map { ($_->{name} || 'unnamed') => join(',', sort @{$_->{columns}}) } @{$db_schema->{unique_constraints}   || []};
    my %result_uniques = map { ($_->{name} || 'unnamed') => join(',', sort @{$_->{columns}}) } @{$result_schema->{unique_constraints} || []};

    # Build reverse lookup: column-set => db constraint name (for unnamed matching)
    my %db_cols_to_name = reverse %db_uniques;

    my %matched_db;    # db names that have been matched
    my %matched_result; # result names that have been matched

    # First pass: exact name matches
    foreach my $name (keys %db_uniques) {
        if (exists $result_uniques{$name}) {
            $matched_db{$name} = 1;
            $matched_result{$name} = 1;
            if ($db_uniques{$name} ne $result_uniques{$name}) {
                push @differences, {
                    type => 'unique_constraint_mismatch',
                    attribute => "add_unique_constraint ($name)",
                    table_value => $db_uniques{$name},
                    result_value => $result_uniques{$name},
                    description => "Unique constraint '$name' column mismatch"
                };
            }
        }
    }

    # Second pass: match 'unnamed' Result constraints to DB constraints by column set
    foreach my $rname (keys %result_uniques) {
        next if $matched_result{$rname};
        my $rcols = $result_uniques{$rname};
        if (exists $db_cols_to_name{$rcols}) {
            my $db_name = $db_cols_to_name{$rcols};
            $matched_db{$db_name} = 1;
            $matched_result{$rname} = 1;
            # Columns match - constraint exists in both, just named differently (OK)
        }
    }

    # Report DB constraints not matched
    foreach my $name (keys %db_uniques) {
        next if $matched_db{$name};
        push @differences, {
            type => 'unique_constraint_missing_in_result',
            attribute => "add_unique_constraint ($name)",
            table_value => $db_uniques{$name},
            result_value => undef,
            description => "Unique constraint '$name' missing in Result file"
        };
    }

    # Report Result constraints not matched
    foreach my $name (keys %result_uniques) {
        next if $matched_result{$name};
        push @differences, {
            type => 'unique_constraint_missing_in_table',
            attribute => "add_unique_constraint ($name)",
            table_value => undef,
            result_value => $result_uniques{$name},
            description => "Unique constraint '$name' exists in Result file but not in database"
        };
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

    # is_* booleans: undef means "not set" = false = 0, so normalise BEFORE the undef-guard
    if ($attribute =~ /^is_/) {
        return (defined $value && $value) ? 1 : 0;
    }

    # extra: undef and '' are both "nothing extra" — treat as equal
    if ($attribute eq 'extra') {
        return '' unless defined $value;
        return ref($value) ? '' : "$value";
    }

    return undef unless defined $value;

    if ($attribute eq 'data_type') {
        return $self->normalize_data_type($value);
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
    # Delegate to canonical Parser for consistent column extraction (important for missing fields display)
    return Comserv::Util::Schema::ResultParser->new->get_result_file_schema($file_path);
}

sub parse_result_file_columns {
    my ($self, $text) = @_;
    # Delegate to Parser (single robust impl)
    return Comserv::Util::Schema::ResultParser->new->parse_result_file_columns($text);
}

=head2 clean_scalar_refs

Recursively clean scalar references from data structures for JSON serialization

# AJAX endpoint: Create result file from database table
# WARNING: This is the NON-PREFERRED direction. The preferred workflow is:
#   1. Create the Result file first (it is the authoritative schema definition)
#   2. Then run create_table_from_result to create the DB table from the Result file
# Creating a Result file from an existing table is a recovery/catch-up operation only.
sub create_result_from_table :Chained('base') :PathPart('create-result-from-table') :Args(0) {
    my ($self, $c) = @_;
    
    $c->response->content_type('application/json; charset=utf-8');
    
    my $table_name = $c->req->param('table_name');
    my $database = $c->req->param('database');
    
    unless ($table_name && $database) {
        $c->response->body(encode_json({ error => 'Missing required parameters' }));
        return;
    }
    
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'create_result_from_table',
        "NON-PREFERRED DIRECTION: Creating Result file FROM table '$table_name'. "
        . "Preferred workflow: create Result file first, then use create_table_from_result.");
    
    try {
        my $schema = $database eq 'Ency' ? $c->model('DBEncy') : $c->model('DBForager');
        
        # Get table structure using internal DBI system
        my $table_fields = $self->get_table_structure_via_model($c, $database, $table_name);
        
        unless (@$table_fields) {
            $c->response->body(encode_json({ error => 'Table not found or has no fields' }));
            return;
        }
        
        # Create result file
        my $result_file_content = $self->generate_result_file_content($table_name, $table_fields, $database);
        my $result_file_path = $self->determine_result_file_path($c, $table_name, $database);
        
        # Ensure directory exists
        my $result_dir = dirname($result_file_path);
        make_path($result_dir) unless -d $result_dir;
        
        # Write result file
        $self->_write_result_file_safe($result_file_path, $result_file_content);
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_result_from_table', 
            "Successfully created result file $result_file_path for table $table_name");
        
        $c->response->body(encode_json({
            success => 1,
            message => "Successfully created result file for $table_name",
            file_path => $result_file_path,
            fields_exported => scalar(@$table_fields),
            workflow_warning => "NON-PREFERRED DIRECTION: Result file was generated from the database table. "
                . "Review and correct the generated file — do not treat it as authoritative. "
                . "Going forward, create the Result file first, then use 'Create Table from Result'.",
            preferred_direction => "Result file first \x{2192} Create Table from Result",
        }));
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_result_from_table', 
            "Result file creation failed: $_");
        $c->response->body(encode_json({ error => "Result file creation failed: $_" }));
    };
}

# AJAX endpoint: Sync table schema to result file
sub sync_table_to_result :Chained('base') :PathPart('sync-table-to-result') :Args(0) {
    my ($self, $c) = @_;
    
    $c->response->content_type('application/json; charset=utf-8');
    
    my $table_name = $c->req->param('table_name');
    my $database = $c->req->param('database');
    
    unless ($table_name && $database) {
        $c->response->body(encode_json({ error => 'Missing required parameters' }));
        return;
    }
    
    try {
        my $result = $self->sync_table_to_result_file($c, $table_name, $database);
        $c->response->body(encode_json($result));
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'sync_table_to_result', 
            "Table to result sync failed: $_");
        $c->response->body(encode_json({ error => "Sync failed: $_" }));
    };
}

# AJAX endpoint: Sync result file to table schema
sub sync_result_to_table :Chained('base') :PathPart('sync-result-to-table') :Args(0) {
    my ($self, $c) = @_;
    
    $c->response->content_type('application/json; charset=utf-8');
    
    my $table_name = $c->req->param('table_name');
    my $database = $c->req->param('database');
    
    unless ($table_name && $database) {
        $c->response->body(encode_json({ error => 'Missing required parameters' }));
        return;
    }
    
    try {
        my $result = $self->sync_result_to_table_schema($c, $table_name, $database);
        $c->response->body(encode_json($result));
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'sync_result_to_table', 
            "Result to table sync failed: $_");
        $c->response->body(encode_json({ error => "Sync failed: $_" }));
    };
}

# Helper method: Sync table schema to result file
sub sync_table_to_result_file {
    my ($self, $c, $table_name, $database) = @_;
    
    my $schema = $database eq 'Ency' ? $c->model('DBEncy') : $c->model('DBForager');
    
    # Get current table structure using internal DBI system
    my $table_fields = $self->get_table_structure_via_model($c, $database, $table_name);
    
    # Find or determine result file path
    my $result_file_path = $self->find_result_file_for_table($c, $table_name);
    $result_file_path ||= $self->determine_result_file_path($c, $table_name, $database);
    
    # Generate updated result file content
    my $result_content = $self->generate_result_file_content($table_name, $table_fields, $database);
    
    # Backup existing file if it exists
    if (-f $result_file_path) {
        my $backup_path = $result_file_path . '.backup.' . time();
        copy($result_file_path, $backup_path);
    }
    
    # Ensure directory exists
    my $result_dir = dirname($result_file_path);
    make_path($result_dir) unless -d $result_dir;
    
    # Write updated result file
    $self->_write_result_file_safe($result_file_path, $result_content);
    
    return {
        success => 1,
        message => "Successfully synchronized table $table_name to result file",
        file_path => $result_file_path,
        fields_synchronized => scalar(@$table_fields)
    };
}

# Helper method: Sync result file to table schema
sub sync_result_to_table_schema {
    my ($self, $c, $table_name, $database) = @_;
    
    # Find result file
    my $result_file_path = $self->find_result_file_for_table($c, $table_name);
    
    unless ($result_file_path && -f $result_file_path) {
        return { error => "Result file not found for table $table_name" };
    }
    
    # Parse result file fields
    my $result_fields = $self->parse_result_file_fields($result_file_path);
    
    unless (@$result_fields) {
        return { error => "No fields found in result file" };
    }
    
    # Use DBSchemaManager to modify the table
    my $db_manager = $c->model('DBSchemaManager');
    my $schema_model = $database eq 'Ency' ? 'DBEncy' : 'DBForager';
    
    my $alter_result = $db_manager->sync_table_with_result_fields($table_name, $result_fields, $schema_model);
    
    return $alter_result;
}

# Helper method: Generate result file content from table structure
sub generate_result_file_content {
    my ($self, $table_name, $fields, $database) = @_;
    
    # Convert table name to class name
    my $class_name = join('', map { ucfirst(lc($_)) } split(/_/, $table_name));
    my $namespace = $database eq 'Ency' ? 'Comserv::Model::Schema::Ency::Result' : 'Comserv::Model::Schema::Forager::Result';
    
    my $content = qq{package ${namespace}::${class_name};

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('${table_name}');

__PACKAGE__->add_columns(
};

    foreach my $field (@$fields) {
        my $field_name = $field->{name};
        my $data_type = $self->convert_mysql_to_dbic_type($field->{type});
        
        $content .= qq{    "${field_name}" => {
        data_type => "${data_type}",
        is_nullable => } . ($field->{null} eq 'YES' ? '1' : '0') . qq{,
};
        
        # Add size if applicable
        if ($field->{type} =~ /\((\d+)\)/) {
            $content .= qq{        size => $1,
};
        }
        
        # Add default value if present
        if (defined $field->{default} && $field->{default} ne '') {
            $content .= qq{        default_value => '$field->{default}',
};
        }
        
        # Add auto_increment if present
        if ($field->{extra} && $field->{extra} =~ /auto_increment/i) {
            $content .= qq{        is_auto_increment => 1,
};
        }
        
        $content .= qq{    },
};
    }
    
    $content .= qq{);

# Set primary key
};
    
    # Find primary key fields
    my @pk_fields = grep { $_->{key} eq 'PRI' } @$fields;
    if (@pk_fields) {
        my $pk_list = join(', ', map { qq{"$_->{name}"} } @pk_fields);
        $content .= qq{__PACKAGE__->set_primary_key($pk_list);

};
    }
    
    $content .= qq{1;

=head1 NAME

${namespace}::${class_name} - Result class for '${table_name}' table

=head1 DESCRIPTION

Auto-generated DBIx::Class result class for the '${table_name}' table.
Generated from database schema on } . strftime('%Y-%m-%d %H:%M:%S', localtime()) . qq{

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

sub _table_to_class_name {
    my ($table_name) = @_;
    return join('', map { ucfirst(lc($_)) } split(/_/, $table_name));
}

sub get_result_file_path {
    my ($self, $c, $table_name, $database) = @_;

    my $class_name = _table_to_class_name($table_name);
    my $ns = ($database && lc($database) eq 'forager') ? 'Forager' : 'Ency';

    my $base_path = $c->path_to('lib', 'Comserv', 'Model', 'Schema', $ns, 'Result');
    return File::Spec->catfile($base_path, "$class_name.pm");
}

sub determine_result_file_path {
    my ($self, $c, $table_name, $database) = @_;
    return $self->get_result_file_path($c, $table_name, $database);
}

=head1 AUTHOR

Shanta McBain

=head1 LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

sub _strip_fk_constraints {
    my ($sql) = @_;
    my @lines = split /\n/, $sql;
    my @kept;
    for my $line (@lines) {
        next if $line =~ /^\s*CONSTRAINT\s+/i;
        next if $line =~ /^\s*INDEX\s+.*_idx_/i && $line =~ /REFERENCES/i;
        push @kept, $line;
    }
    my $result = join "\n", @kept;
    $result =~ s/,(\s*\n\s*\))/\n)/g;
    return $result;
}

# ============================================================
# DRILL-DOWN CHAINED ACTIONS (Server → Database → Table → Field)
# Reuses the existing .tt files in admin/schema_compare/
# ============================================================

sub schema_compare :Path('/admin/schema_compare') :Args(0) {
    my ($self, $c) = @_;

    require Comserv::Model::RemoteDB;
    my $remote_db = Comserv::Model::RemoteDB->new();
    $remote_db->config({});
    my $all_conns = $remote_db->get_all_connections();

    my @target_ips = ('192.168.1.198', '192.168.1.199', '192.168.1.20', '192.168.1.21');

    my @primary_conns;
    foreach my $name (keys %$all_conns) {
        next if $name =~ /^(backup_|local_|zerotier_|sqlite_|dev_)/i;
        push @primary_conns, $name;
    }

    my @servers;
    foreach my $ip (@target_ips) {
        my @conns_for_ip = grep { ($all_conns->{$_}{config}{host} // '') eq $ip } @primary_conns;
        my $db_count = scalar(@conns_for_ip);

        my %type_count;
        foreach my $c (@conns_for_ip) {
            my $t = $all_conns->{$c}{config}{db_type} // 'mysql';
            $type_count{$t}++;
        }
        my $type_display = join(', ', map { ucfirst($_) . ": $type_count{$_}" } sort keys %type_count);

        # Safe cached status only (no live connect on normal page load)
        our %SERVER_STATUS_CACHE;
        my $status = $SERVER_STATUS_CACHE{$ip} || {
            running     => 0,
            table_count => 0,
            status      => 'unknown',
        };

        push @servers, {
            name         => $ip,
            ip           => $ip,
            db_count     => $db_count,
            type_display => $type_display,
            running      => $status->{running},
            table_count  => $status->{table_count},
            status       => $status->{status},
        };
    }

    $c->stash(
        template      => 'admin/schema_compare.tt',
        servers       => \@servers,
        server_count  => scalar(@servers),
    );
}

sub schema_compare_server :Path('/admin/schema_compare/server') :Args(1) {
    my ($self, $c, $server_ip) = @_;

    require Comserv::Model::RemoteDB;
    my $remote_db = Comserv::Model::RemoteDB->new();
    $remote_db->config({});
    my $all_conns = $remote_db->get_all_connections();

    # Get ALL connections for this IP
    my @conns_for_ip = grep { ($all_conns->{$_}{config}{host} // '') eq $server_ip } keys %$all_conns;

    my @databases;
    foreach my $conn_name (@conns_for_ip) {
        my $cfg = $all_conns->{$conn_name}{config};
        my $db_name = $cfg->{database} // $conn_name;
        my $db_type = $cfg->{db_type} // 'mysql';

        my $dbh = eval { $remote_db->get_connection(undef, $conn_name) };
        next unless $dbh;

        # Get basic stats
        my $table_count = 0;
        my $size_kb     = 0;
        eval {
            my $sth = $dbh->prepare("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = ?");
            $sth->execute($db_name);
            ($table_count) = $sth->fetchrow_array;
            $sth->finish;

            # Rough size in KB (data_length + index_length)
            $sth = $dbh->prepare("
                SELECT ROUND(SUM(data_length + index_length) / 1024, 1) 
                FROM information_schema.tables 
                WHERE table_schema = ?
            ");
            $sth->execute($db_name);
            ($size_kb) = $sth->fetchrow_array;
            $sth->finish;
        };

        my $size_display = $size_kb ? "$size_kb KB" : '—';

        push @databases, {
            name        => $db_name,
            type        => $db_type,
            table_count => $table_count,
            size        => $size_display,
            size_kb     => $size_kb || 0,
            status      => 'active',
        };

        $dbh->disconnect;
    }

    $c->stash(
        template  => 'admin/schema_compare/databases.tt',
        server    => { name => $server_ip, ip => $server_ip, container_count => 0 },
        databases => \@databases,
    );
}

sub schema_compare_database :Path('/admin/schema_compare/server') :Args(3) {
    my ($self, $c, $server_ip, undef, $db_name) = @_;

    require Comserv::Model::RemoteDB;
    my $remote_db = Comserv::Model::RemoteDB->new();
    $remote_db->config({});
    my $all_conns = $remote_db->get_all_connections();

    # Find a connection that matches this server + database
    my ($conn_name) = grep {
        my $cfg = $all_conns->{$_}{config};
        ($cfg->{host} // '') eq $server_ip &&
        (($cfg->{database} // $_) eq $db_name)
    } keys %$all_conns;

    # Get live tables from the database
    my %db_tables;  # name => { row_count, size_kb, size }
    if ($conn_name) {
        my $dbh = eval { $remote_db->get_connection(undef, $conn_name) };
        if ($dbh) {
            # Verify which database we are actually connected to
            my ($actual_db) = $dbh->selectrow_array("SELECT DATABASE()");
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'schema_compare_database',
                "Connected via $conn_name to database: $actual_db (requested: $db_name)");

            eval {
                # Use SHOW TABLES for authoritative count (matches MariaDB client exactly)
                my $sth = $dbh->prepare("SHOW TABLES");
                $sth->execute();
                my @all_tables;
                while (my $row = $sth->fetchrow_array) {
                    push @all_tables, $row;
                }
                $sth->finish;

                # Now get detailed stats for each table
                foreach my $tname (@all_tables) {
                    my ($row_count, $size_kb) = (0, 0);
                    eval {
                        my $info_sth = $dbh->prepare("
                            SELECT 
                                table_rows,
                                ROUND((data_length + index_length) / 1024, 1) AS size_kb
                            FROM information_schema.tables 
                            WHERE table_schema = ? AND table_name = ?
                        ");
                        $info_sth->execute($db_name, $tname);
                        ($row_count, $size_kb) = $info_sth->fetchrow_array;
                        $info_sth->finish;
                    };

                    $db_tables{ lc($tname) } = {
                        name        => $tname,
                        row_count   => $row_count || 0,
                        size_kb     => $size_kb || 0,
                        size        => ($size_kb ? "$size_kb KB" : '—'),
                        status      => 'active',
                        in_table    => 1,
                    };
                }
                # Old query removed - using SHOW TABLES above for authoritative count
            };
            $dbh->disconnect;
        }
    }

    # === Determine which Result schema to use based on database name ===
    my $result_schema = lc($db_name) =~ /forager/ ? 'forager' : 'ency';

    # Discover Result files for the relevant schema
    my $result_mapping = {};
    my $result_count   = 0;
    my @result_files   = ();
    my @result_extract_failures = ();
    eval {
        require Comserv::Util::Schema::ResultParser;
        my $parser = Comserv::Util::Schema::ResultParser->new();
        @result_files = $parser->get_all_result_files($result_schema, $c);
        $result_count = scalar(@result_files);

        # Build mapping with failure tracking
        foreach my $rf (@result_files) {
            my $table_name = $parser->extract_table_name_from_result_file($rf->{path});
            if ($table_name) {
                $result_mapping->{lc($table_name)} = {
                    result_name => $rf->{name},
                    result_path => $rf->{path},
                };
            } else {
                push @result_extract_failures, {
                    name => $rf->{name},
                    path => $rf->{path},
                };
            }
        }
    };

    # Also keep ENCY total for the verification header (always shown)
    my $ency_result_count = 0;
    my @ency_result_files = ();
    eval {
        require Comserv::Util::Schema::ResultParser;
        my $parser = Comserv::Util::Schema::ResultParser->new();
        @ency_result_files = $parser->get_all_result_files('ency', $c);
        $ency_result_count = scalar(@ency_result_files);
    };

    # === Build three-way split using actual Result file mapping ===
    my (@both, @table_only, @result_only);

    # Track which result table names were matched (for debugging)
    my %matched_result_names;

    foreach my $tname (sort keys %db_tables) {
        my $tinfo = $db_tables{$tname};
        if (exists $result_mapping->{lc($tname)}) {
            $matched_result_names{lc($tname)} = 1;
            push @both, {
                %$tinfo,
                has_result  => 1,
                result_name => $result_mapping->{lc($tname)}{result_name},
            };
        } else {
            push @table_only, {
                %$tinfo,
                has_result  => 0,
                result_name => undef,
            };
        }
    }

    # Explicitly find result files whose table name is NOT in the live DB
    my @orphaned_result_files = ();
    foreach my $tname (sort keys %$result_mapping) {
        if (!exists $db_tables{lc($tname)}) {
            push @orphaned_result_files, {
                result_name => $result_mapping->{$tname}{result_name},
                extracted_table_name => $tname,
            };
            push @result_only, {
                name        => $tname,
                row_count   => 0,
                size_kb     => 0,
                size        => '—',
                status      => 'result-only',
                in_table    => 0,
                has_result  => 1,
                result_name => $result_mapping->{$tname}{result_name},
            };
        }
    }

    # Extra diagnostic stash
    my $db_table_count = scalar(keys %db_tables);
    my $matched_count = scalar(keys %matched_result_names);
    my $orphaned_count = scalar(@orphaned_result_files);

    $c->stash(
        template => 'admin/schema_compare/tables.tt',
        server   => { name => $server_ip, ip => $server_ip },
        db       => { name => $db_name },
        both       => \@both,
        table_only => \@table_only,
        result_only=> \@result_only,
        ency_result_count => $ency_result_count,
        result_schema     => $result_schema,
        result_count      => $result_count,
        result_files      => \@result_files,
        result_extract_failures => \@result_extract_failures,
        db_table_count    => $db_table_count,
        matched_count     => $matched_count,
        orphaned_result_files => \@orphaned_result_files,
        orphaned_count      => $orphaned_count,
    );
}

sub schema_compare_table :Path('/admin/schema_compare/server') :Args(5) {
    my ($self, $c, $server_ip, undef, $db_name, undef, $table_name) = @_;
    $c->stash(
        template => 'admin/schema_compare/fields.tt',
        server   => { name => $server_ip },
        db       => { name => $db_name },
        table    => { name => $table_name },
        fields   => [],
    );
}

# AJAX endpoint: refresh status for one server IP (live connect test)
sub refresh_server_status :Path('/admin/schema_compare/refresh_server') :Args(1) {
    my ($self, $c, $server_ip) = @_;

    require Comserv::Model::RemoteDB;
    my $remote_db = Comserv::Model::RemoteDB->new();
    $remote_db->config({});
    my $all_conns = $remote_db->get_all_connections();

    my @conns_for_ip = grep { ($all_conns->{$_}{config}{host} // '') eq $server_ip } keys %$all_conns;

    my $running = 0;
    my $table_count = 0;
    foreach my $c (@conns_for_ip) {
        my $dbh = eval { $remote_db->get_connection(undef, $c) };
        if ($dbh) {
            eval {
                my $sth = $dbh->prepare("SELECT 1");
                $sth->execute();
                $sth->finish;
                $running = 1;

                # Sum tables from EVERY reachable database on this IP
                $sth = $dbh->prepare("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = ?");
                $sth->execute($all_conns->{$c}{config}{database} // $c);
                my ($cnt) = $sth->fetchrow_array;
                $table_count += $cnt || 0;
                $sth->finish;
            };
            $dbh->disconnect;
            # do NOT break – we want the sum from all databases
        }
    }

    our %SERVER_STATUS_CACHE;
    $SERVER_STATUS_CACHE{$server_ip} = {
        running     => $running,
        table_count => $table_count,
        status      => $running ? 'active' : 'offline',
    };

    $c->stash(json => {
        success     => 1,
        ip          => $server_ip,
        running     => $running,
        table_count => $table_count,
        status      => $running ? 'active' : 'offline',
    });
    $c->forward('View::JSON');
}

__PACKAGE__->meta->make_immutable;

1;
