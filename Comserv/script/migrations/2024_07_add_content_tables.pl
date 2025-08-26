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

$migration->install_version({
    version => 7,
    ddl => [
        # Create Content table
        q{
            CREATE TABLE content (
                id INTEGER PRIMARY KEY AUTO_INCREMENT,
                title VARCHAR(255) NOT NULL,
                body TEXT NOT NULL,
                meta_description TEXT,
                meta_keywords TEXT,
                created_at DATETIME,
                updated_at DATETIME,
                created_by INTEGER NOT NULL,
                updated_by INTEGER NOT NULL,
                status VARCHAR(20) DEFAULT 'draft',
                FOREIGN KEY (created_by) REFERENCES users(id),
                FOREIGN KEY (updated_by) REFERENCES users(id)
            )
        },
        # Create Documentation table
        q{
            CREATE TABLE documentation (
                id INTEGER PRIMARY KEY AUTO_INCREMENT,
                title VARCHAR(255) NOT NULL,
                content TEXT NOT NULL,
                section VARCHAR(255) NOT NULL,
                version VARCHAR(50) NOT NULL,
                created_at DATETIME,
                updated_at DATETIME,
                created_by INTEGER NOT NULL,
                updated_by INTEGER NOT NULL,
                FOREIGN KEY (created_by) REFERENCES users(id),
                FOREIGN KEY (updated_by) REFERENCES users(id)
            )
        },
        # Create Menu table
        q{
            CREATE TABLE menu (
                id INTEGER PRIMARY KEY AUTO_INCREMENT,
                name VARCHAR(255) NOT NULL,
                description TEXT,
                parent_id INTEGER,
                order_num INTEGER,
                created_at DATETIME,
                updated_at DATETIME,
                FOREIGN KEY (parent_id) REFERENCES menu(id)
            )
        },
        # Create MenuItem table
        q{
            CREATE TABLE menu_item (
                id INTEGER PRIMARY KEY AUTO_INCREMENT,
                menu_id INTEGER NOT NULL,
                title VARCHAR(255) NOT NULL,
                url VARCHAR(255),
                order_num INTEGER,
                created_at DATETIME,
                updated_at DATETIME,
                FOREIGN KEY (menu_id) REFERENCES menu(id)
            )
        },
        # Create Navigation table
        q{
            CREATE TABLE navigation (
                id INTEGER PRIMARY KEY AUTO_INCREMENT,
                name VARCHAR(255) NOT NULL,
                url VARCHAR(255),
                parent_id INTEGER,
                order_num INTEGER,
                created_at DATETIME,
                updated_at DATETIME,
                FOREIGN KEY (parent_id) REFERENCES navigation(id)
            )
        },
        # Create Media table
        q{
            CREATE TABLE media (
                id INTEGER PRIMARY KEY AUTO_INCREMENT,
                title VARCHAR(255) NOT NULL,
                file_path VARCHAR(255) NOT NULL,
                file_type VARCHAR(50),
                size INTEGER,
                created_at DATETIME,
                updated_at DATETIME
            )
        },
        # Create ContentMedia junction table
        q{
            CREATE TABLE content_media (
                content_id INTEGER NOT NULL,
                media_id INTEGER NOT NULL,
                order_num INTEGER,
                PRIMARY KEY (content_id, media_id),
                FOREIGN KEY (content_id) REFERENCES content(id),
                FOREIGN KEY (media_id) REFERENCES media(id)
            )
        },
        # Add other tables here...
    ],
});

1;
