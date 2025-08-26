package Comserv::Model::Schema::Ency::Result::System::Site;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('sites');
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    name => {
        data_type => 'varchar',
        size => 255,
    },
    description => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    affiliate => {
        data_type => 'integer',
    },
    pid => {
        data_type => 'integer',
    },
    auth_table => {
        data_type => 'varchar',
        size => 255,
    },
    home_view => {
        data_type => 'varchar',
        size => 255,
    },
    app_logo => {
        data_type => 'varchar',
        size => 255,
    },
    app_logo_alt => {
        data_type => 'varchar',
        size => 255,
    },
    app_logo_width => {
        data_type => 'integer',
    },
    app_logo_height => {
        data_type => 'integer',
    },
    css_view_name => {
        data_type => 'varchar',
        size => 255,
    },
    mail_from => {
        data_type => 'varchar',
        size => 255,
    },
    mail_to => {
        data_type => 'varchar',
        size => 255,
    },
    mail_to_discussion => {
        data_type => 'varchar',
        size => 255,
    },
    mail_to_admin => {
        data_type => 'varchar',
        size => 255,
    },
    mail_to_user => {
        data_type => 'varchar',
        size => 255,
    },
    mail_to_client => {
        data_type => 'varchar',
        size => 255,
    },
    mail_replyto => {
        data_type => 'varchar',
        size => 255,
    },
    site_display_name => {
        data_type => 'varchar',
        size => 255,
    },
    document_root_url => {
        data_type => 'varchar',
        size => 255,
    },
    link_target => {
        data_type => 'varchar',
        size => 255,
    },
    http_header_params => {
        data_type => 'varchar',
        size => 255,
    },
    image_root_url => {
        data_type => 'varchar',
        size => 255,
    },
    global_datafiles_directory => {
        data_type => 'varchar',
        size => 255,
    },
    templates_cache_directory => {
        data_type => 'varchar',
        size => 255,
    },
    app_datafiles_directory => {
        data_type => 'varchar',
        size => 255,
    },
    datasource_type => {
        data_type => 'varchar',
        size => 255,
    },
    cal_table => {
        data_type => 'varchar',
        size => 255,
    },
    http_header_description => {
        data_type => 'varchar',
        size => 255,
    },
    http_header_keywords => {
        data_type => 'varchar',
        size => 255,
    },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->has_many(user_sites => 'Comserv::Model::Schema::Ency::Result::UserSite', 'site_id');
__PACKAGE__->many_to_many(users => 'user_sites', 'user');
__PACKAGE__->has_many(project_sites => 'Comserv::Model::Schema::Result::ProjectSite', 'site_id');
__PACKAGE__->many_to_many(projects => 'project_sites', 'project');
__PACKAGE__->has_many(site_domains => 'Comserv::Model::Schema::Ency::Result::SiteDomain', 'site_id');

1;