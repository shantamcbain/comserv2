#!/usr/bin/perl
use strict;
use warnings;
use lib '../lib';
use Comserv::Model::Schema::Forager;
use Comserv::Model::Schema::Ency;

print "=== Simple Page Migration: Forager to Ency ===\n";

# Database connections
my $forager = Comserv::Model::Schema::Forager->connect(
    'dbi:mysql:dbname=forager', 'shanta_forager', 'UA=nPF8*m+T#'
);

my $ency = Comserv::Model::Schema::Ency->connect(
    'dbi:mysql:dbname=ency', 'shanta_forager', 'UA=nPF8*m+T#'
);

# Get all pages from Forager
my $forager_pages = $forager->resultset('Page')->search({});
my $total = $forager_pages->count;
my $migrated = 0;
my $errors = 0;

print "Found $total pages to migrate\n";

while (my $old_page = $forager_pages->next) {
    eval {
        # Map roles from menu
        my $roles = 'public';
        if ($old_page->menu eq 'Admin') {
            $roles = 'admin';
        } elsif ($old_page->menu eq 'member') {
            $roles = 'member';
        }
        
        # Create new page
        my $new_page = $ency->resultset('Page')->create({
            sitename => $old_page->sitename,
            menu => $old_page->menu,
            page_code => $old_page->page_code,
            title => $old_page->app_title,
            body => $old_page->body,
            description => $old_page->description,
            keywords => $old_page->keywords,
            link_order => $old_page->link_order,
            status => $old_page->status eq '1' ? 'active' : 'inactive',
            roles => $roles,
            created_by => $old_page->username_of_poster || 'admin'
        });
        
        $migrated++;
        print "Migrated: " . $old_page->page_code . " -> " . $new_page->id . "\n";
        
    } catch {
        $errors++;
        print "Error migrating " . $old_page->page_code . ": $_\n";
    };
}

print "\n=== Migration Complete ===\n";
print "Total pages: $total\n";
print "Migrated: $migrated\n";
print "Errors: $errors\n";
print "Success rate: " . sprintf("%.1f", ($migrated/$total)*100) . "%\n";