#!/usr/bin/env perl
use strict;
use warnings;
use DBIx::Class::Migration;
use FindBin;
use lib "$FindBin::Bin/../../lib";

my $migration = DBIx::Class::Migration->new(
    schema_class => 'Comserv::Model::Schema::Ency',
    target_dir   => "$FindBin::Bin/../../share/migrations",
);

$migration->prepare;

# Create new tables
$migration->install_version({
    version => 2,
    ddl => [
        # Create menus table
        q{
            CREATE TABLE menus (
                id INTEGER PRIMARY KEY AUTO_INCREMENT,
                name VARCHAR(255) NOT NULL,
                description TEXT,
                site_id INTEGER NOT NULL,
                created_at DATETIME,
                updated_at DATETIME,
                FOREIGN KEY (site_id) REFERENCES sites(id)
            )
        },
        # Create menu_items table
        q{
            CREATE TABLE menu_items (
                id INTEGER PRIMARY KEY AUTO_INCREMENT,
                menu_id INTEGER NOT NULL,
                title VARCHAR(255) NOT NULL,
                url VARCHAR(255),
                page_id INTEGER,
                parent_id INTEGER,
                `order` INTEGER DEFAULT 0,
                created_at DATETIME,
                updated_at DATETIME,
                FOREIGN KEY (menu_id) REFERENCES menus(id),
                FOREIGN KEY (page_id) REFERENCES pages(id),
                FOREIGN KEY (parent_id) REFERENCES menu_items(id)
            )
        },
        # Alter pages table
        q{
            ALTER TABLE pages
            ADD COLUMN last_modified_by INTEGER,
            ADD COLUMN last_modified_at DATETIME,
            ADD COLUMN social_media TEXT,
            ADD FOREIGN KEY (last_modified_by) REFERENCES users(id)
        },
    ],
});

1;
