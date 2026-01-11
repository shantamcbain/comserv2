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
    
    unless ($c->user_exists && $c->check_user_roles('admin')) {
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
    
    unless ($c->user_exists && $c->check_user_roles('admin')) {
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
        my $result = $self->update_table_field_from_result($c, $table_name, $field_name, $database, $result_field_info);
        
        $c->stash(json => {
            success => 1,
            message => "Successfully synced result field '$field_name' to table",
            field_info => $result_field_info
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
    
    unless ($c->user_exists && $c->check_user_roles('admin')) {
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

=head2 get_table_field_info

Get database table field information

=cut

sub get_table_field_info {
    my ($self, $c, $table_name, $field_name, $database) = @_;
    
    my $model_name = $database eq 'ency' ? 'DBEncy' : 'DBForager';
    my $schema = $c->model($model_name)->schema;
    
    my $dbh = $schema->storage->dbh;
    my $sth = $dbh->column_info(undef, undef, $table_name, $field_name);
    my $column_info = $sth->fetchrow_hashref;
    
    if (!$column_info) {
        die "Field '$field_name' not found in table '$table_name'";
    }
    
    return {
        data_type => $column_info->{TYPE_NAME} || $column_info->{DATA_TYPE},
        size => $column_info->{COLUMN_SIZE},
        is_nullable => $column_info->{NULLABLE} ? 1 : 0,
        is_auto_increment => $column_info->{IS_AUTOINCREMENT} ? 1 : 0,
        default_value => $column_info->{COLUMN_DEF}
    };
}

=head2 get_result_field_info

Get Result file field information

=cut

sub get_result_field_info {
    my ($self, $c, $table_name, $field_name, $database) = @_;
    
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
    
    if ($content =~ /__PACKAGE__->add_columns\(\s*(.*?)\s*\);/s) {
        my $columns_section = $1;
        my $field_info = {};
        
        if ($columns_section =~ /(?:^|\s|,)\s*'?$field_name'?\s*=>\s*\{([^}]+)\}/s) {
            my $field_def = $1;
            
            $field_info->{data_type} = $1 if $field_def =~ /data_type\s*=>\s*["']([^"']+)["']/;
            $field_info->{size} = $1 if $field_def =~ /size\s*=>\s*(\d+)/;
            $field_info->{is_nullable} = $1 if $field_def =~ /is_nullable\s*=>\s*([01])/;
            $field_info->{is_auto_increment} = $1 if $field_def =~ /is_auto_increment\s*=>\s*([01])/;
            $field_info->{default_value} = $1 if $field_def =~ /default_value\s*=>\s*["']([^"']*)["']/;
            
            return $field_info;
        }
        
        if ($columns_section =~ /["']$field_name["']\s*,\s*\{([^}]+)\}/s) {
            my $field_def = $1;
            
            $field_info->{data_type} = $1 if $field_def =~ /data_type\s*=>\s*["']([^"']+)["']/;
            $field_info->{size} = $1 if $field_def =~ /size\s*=>\s*(\d+)/;
            $field_info->{is_nullable} = $1 if $field_def =~ /is_nullable\s*=>\s*([01])/;
            $field_info->{is_auto_increment} = $1 if $field_def =~ /is_auto_increment\s*=>\s*([01])/;
            $field_info->{default_value} = $1 if $field_def =~ /default_value\s*=>\s*["']([^"']*)["']/;
            
            return $field_info;
        }
    }
    
    die "Field '$field_name' not found in result file";
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
    $new_field_def .= ", size => $table_field_info->{size}" if $table_field_info->{size};
    $new_field_def .= ", is_nullable => $table_field_info->{is_nullable}";
    $new_field_def .= ", is_auto_increment => 1" if $table_field_info->{is_auto_increment};
    $new_field_def .= ", default_value => '$table_field_info->{default_value}'" if defined $table_field_info->{default_value};
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
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_table_field_from_result',
        "Would update table '$table_name' field '$field_name' with result file values: " . 
        Data::Dumper::Dumper($result_field_info));
    
    return 1;
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
        $content .= "    $column_name => {\n";
        $content .= "        data_type => '$col->{data_type}',\n";
        
        if (defined $col->{size}) {
            $content .= "        size => $col->{size},\n";
        }
        
        if ($col->{is_nullable}) {
            $content .= "        is_nullable => 1,\n";
        }
        
        if ($col->{is_auto_increment}) {
            $content .= "        is_auto_increment => 1,\n";
        }
        
        if (defined $col->{default_value}) {
            $content .= "        default_value => '$col->{default_value}',\n";
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
    
    my @result_files = $self->_get_all_result_files($database);
    
    foreach my $result_file (@result_files) {
        my $table_name = $self->_extract_table_name_from_result_file($result_file->{path});
        
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

=head2 _get_all_result_files

Internal helper: Get all Result files for a database

=cut

sub _get_all_result_files {
    my ($self, $database) = @_;
    
    my @result_files = ();
    
    return @result_files;
}

=head2 _extract_table_name_from_result_file

Internal helper: Extract table name from Result file

=cut

sub _extract_table_name_from_result_file {
    my ($self, $result_path) = @_;
    
    my $content = read_file($result_path);
    if ($content =~ /__PACKAGE__->table\(['"](\w+)['"]\)/) {
        return $1;
    }
    
    return undef;
}

=head1 AUTHOR

Shanta McBain

=head1 LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

__PACKAGE__->meta->make_immutable;

1;
