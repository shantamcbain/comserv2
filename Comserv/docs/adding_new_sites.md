# Adding New Sites to Comserv

This guide provides step-by-step instructions for adding new sites to the Comserv system.

## Prerequisites
- Access to the database
- Permission to create new files in the Comserv codebase
- Basic understanding of Perl and Catalyst framework

## Step 1: Create the Site Controller

Create a new controller file in `Comserv/lib/Comserv/Controller/` named after your site (e.g., `MySite.pm`):

```perl
package Comserv::Controller::MySite;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;

BEGIN { extends 'Catalyst::Controller'; }

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

# IMPORTANT: The namespace must match the controller name with the same capitalization
__PACKAGE__->config(namespace => 'MySite');

sub auto :Private {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "MySite controller auto method called");
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Request path: " . $c->req->uri->path);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Request method: " . $c->req->method);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Controller: " . __PACKAGE__);

    # Initialize debug_errors array if needed
    $c->stash->{debug_errors} = [] unless (defined $c->stash->{debug_errors} && ref $c->stash->{debug_errors} eq 'ARRAY');

    # Initialize debug_msg array if needed
    $c->stash->{debug_msg} = [] unless (defined $c->stash->{debug_msg} && ref $c->stash->{debug_msg} eq 'ARRAY');

    return 1; # Allow the request to proceed
}

# Main index page
sub index :Path :Args(0) {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Entered MySite index method");

    # Ensure debug_errors is an array reference
    $c->stash->{debug_errors} = [] unless ref $c->stash->{debug_errors} eq 'ARRAY';
    push @{$c->stash->{debug_errors}}, "Entered MySite index method";

    # Add debug message
    # Ensure debug_msg is an array reference
    $c->stash->{debug_msg} = [] unless ref $c->stash->{debug_msg} eq 'ARRAY';
    push @{$c->stash->{debug_msg}}, "MySite Home Page";

    # Set the template
    $c->stash(
        template => 'MySite/index.tt',
        title => 'MySite',
        # debug_msg is already set as an array above
    );
}

__PACKAGE__->meta->make_immutable;

1;
```

## Step 2: Create the Template

Create a new template directory and file in `Comserv/root/` for your site:

```
mkdir -p Comserv/root/MySite
```

Create the index template file `Comserv/root/MySite/index.tt`:

```html
[% META title = 'MySite Home Page' %]

<div class="container">
    <div class="row">
        <div class="col-md-12">
            <h1>Welcome to MySite</h1>
            <p>This is the home page for MySite.</p>
        </div>
    </div>
</div>
```

## Step 3: Add the Site to the Database

Execute the following SQL commands to add your site to the database:

```sql
-- Add the site to the Site table
INSERT INTO Site (site_code, name, display_name, home_view)
VALUES ('MySite', 'MySite', 'My Site - Description', 'MySite');

-- Get the site_id of the newly created site
SELECT site_id FROM Site WHERE site_code = 'MySite';

-- Add the domain to the SiteDomain table (replace site_id with the actual ID)
INSERT INTO SiteDomain (site_id, domain)
VALUES (123, 'mysite.com');

-- Add additional domains if needed
INSERT INTO SiteDomain (site_id, domain)
VALUES (123, 'mysite.local');
```

## Step 4: Configure the Theme

Add your site to the theme mappings file (`Comserv/root/themes/theme_mappings.json`):

```json
{
  "MySite": "default"
}
```

You can replace "default" with any available theme name.

## Step 5: Test the Site

1. Restart the application server
2. Access your site using the configured domain (e.g., mysite.com)
3. Check the application logs for any errors

## Troubleshooting

If your site is not displaying correctly:

1. Check the application logs for errors
2. Verify the database entries for your site
3. Ensure the controller namespace matches the controller name
4. Confirm the home_view field in the Site table matches the controller name
5. Check that the template file exists in the correct location

## Important Notes

- The capitalization of the controller name and namespace must match
- The home_view field in the Site table must match the controller name exactly
- The site_code in the Site table should match the controller name
- Make sure your domain is properly configured in your DNS or hosts file