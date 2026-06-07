-- Brew SiteName + brew.computersystemconsulting.ca (run against ency / main Comserv DB)
-- Also supports brew.<any-parent-domain> via application code (Site.pm prefix map).

-- Adjust site_id / columns if your sites row already exists.

INSERT INTO sites (
    name, description, affiliate, pid, auth_table, home_view, css_view_name,
    mail_from, mail_to, mail_to_discussion, mail_to_admin, mail_to_user, mail_to_client, mail_replyto,
    site_display_name, app_logo, app_logo_alt, app_logo_width, app_logo_height,
    document_root_url, link_target, image_root_url, http_header_description, http_header_keywords
)
SELECT
    'Brew', 'Brewhouse management', 0, 0, 'users', 'Brew', 'default',
    'helpdesk@computersystemconsulting.ca', 'helpdesk@computersystemconsulting.ca',
    'helpdesk@computersystemconsulting.ca', 'helpdesk@computersystemconsulting.ca',
    'helpdesk@computersystemconsulting.ca', 'helpdesk@computersystemconsulting.ca',
    'helpdesk@computersystemconsulting.ca',
    'Brew — Brewhouse', '/static/images/default_logo.png', 'Brew', 200, 100,
    '/', '_self', '/static/images/', 'Brew brewhouse', 'brew,brewhouse'
FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM sites WHERE name = 'Brew');

INSERT INTO sitedomain (site_id, domain)
SELECT s.id, 'brew.computersystemconsulting.ca'
FROM sites s
WHERE s.name = 'Brew'
  AND NOT EXISTS (SELECT 1 FROM sitedomain WHERE domain = 'brew.computersystemconsulting.ca');

INSERT INTO site_modules (sitename, module_name, enabled)
SELECT 'Brew', 'brew', 1 FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM site_modules WHERE sitename = 'Brew' AND module_name = 'brew');

INSERT INTO site_modules (sitename, module_name, enabled)
SELECT 'Brew', 'accounting', 1 FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM site_modules WHERE sitename = 'Brew' AND module_name = 'accounting');