# Navigation Tables Documentation

This document describes the database tables used for navigation in the Comserv application.

## Overview

The navigation system in Comserv uses two main tables:

1. `internal_links_tb` - Stores internal links for navigation across different site sections
2. `page_tb` - Stores page information for site navigation and content management

These tables are used by the `Navigation` controller to populate navigation menus and links throughout the application.

## Table Definitions

### internal_links_tb

This table stores internal links for navigation across different site sections.

#### JSON Schema

The JSON schema for this table is located at `/sql/json/internal_links_tb.json`.

#### Columns

| Column Name | Data Type | Description |
|-------------|-----------|-------------|
| id | integer | Primary key for the internal links table |
| category | varchar(50) | Category of the link (e.g., Main_links, Member_links, Admin_links, Hosted_link) |
| sitename | varchar(50) | Site name the link belongs to (or 'All' for links that appear on all sites) |
| name | varchar(100) | Display name of the link |
| url | varchar(255) | URL or path for the link |
| target | varchar(20) | Target attribute for the link (e.g., _self, _blank) |
| description | text | Description of the link for administrative purposes |
| link_order | integer | Order in which the link should appear in the navigation |
| status | integer | Status of the link (1 = active, 0 = inactive, 2 = featured) |
| created_at | datetime | Timestamp when the link was created |
| updated_at | datetime | Timestamp when the link was last updated |

#### Indexes

- Primary Key: `id`
- `idx_internal_links_category` on `category`
- `idx_internal_links_sitename` on `sitename`
- `idx_internal_links_status` on `status`

### page_tb

This table stores page information for site navigation and content management.

#### JSON Schema

The JSON schema for this table is located at `/sql/json/page_tb.json`.

#### Columns

| Column Name | Data Type | Description |
|-------------|-----------|-------------|
| id | integer | Primary key for the page table |
| menu | varchar(50) | Menu category the page belongs to (e.g., Main, member, Admin) |
| sitename | varchar(50) | Site name the page belongs to (or 'All' for pages that appear on all sites) |
| name | varchar(100) | Display name of the page |
| url | varchar(255) | URL or path for the page |
| target | varchar(20) | Target attribute for the page link (e.g., _self, _blank) |
| description | text | Description of the page for administrative purposes |
| link_order | integer | Order in which the page should appear in the navigation |
| status | integer | Status of the page (1 = active, 0 = inactive, 2 = featured) |
| created_at | datetime | Timestamp when the page was created |
| updated_at | datetime | Timestamp when the page was last updated |

#### Indexes

- Primary Key: `id`
- `idx_page_menu` on `menu`
- `idx_page_sitename` on `sitename`
- `idx_page_status` on `status`

## Usage

These tables are used by the `Navigation` controller to populate navigation menus and links throughout the application. The controller provides methods to retrieve links and pages for different categories and sites.

### Example Queries

#### Get Main Links for a Site

```perl
my $main_links = $c->model('DBEncy')->resultset('InternalLinksTb')->search({
    category => 'Main_links',
    sitename => [ $site_name, 'All' ]
}, {
    order_by => { -asc => 'link_order' }
});
```

#### Get Member Pages for a Site

```perl
my $member_pages = $c->model('DBEncy')->resultset('PageTb')->search({
    menu => 'member',
    status => 2,
    sitename => [ $site_name, 'All' ]
}, {
    order_by => { -asc => 'link_order' }
});
```

## Table Creation

To create these tables in the database, run the following script:

```bash
perl /home/shanta/PycharmProjects/comserv2/Comserv/script/create_navigation_tables.pl
```

This script will create the tables and populate them with sample data.

## Maintenance

To add new links or pages, you can either:

1. Insert records directly into the database using SQL
2. Use the admin interface (if available)
3. Add entries to the sample data in the SQL files and re-run the creation script

Remember to maintain the proper order of links and pages using the `link_order` column to ensure consistent navigation display.