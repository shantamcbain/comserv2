#!/usr/bin/env python3

file_path = "../lib/Comserv/Controller/Inventory.pm"

with open(file_path, 'r') as f:
    content = f.read()

# Fix the auto method - replace the email navigation code
import re

# Fix the auto method - replace the email navigation code with simplified version
pattern = r'my \$email_navigation = \$c->navigation;\n    if \(\$email_navigation\) {\n        \$email_navigation->add\(\{[^{]+\}\);\n    }'
replacement = '''# Navigation setup moved to comserv_navigation plugin integration
    # Email configuration navigation is automatically handled through Comserv's navigation system
    # See Comserv::Util::ModelCatalog for navigation configuration
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto',
        'Email navigation setup deferred to Comserv navigation system');'''

content = re.sub(pattern, replacement, content, flags=re.DOTALL)

# Add the missing helper functions if they're not present
if 'sub _sitename {' not in content:
    # Find the Helpers section
    helper_pattern = r'(# -------------------------------------------------------------------------\n# Helpers\n# -------------------------------------------------------------------------\n(\s*))'
    match = re.search(helper_pattern, content)
    if match:
        indent = match.group(1)
        # Insert the helper functions after the Helpers header
        helper_functions = f'''{indent}sub _sitename {{
{indent}    my ($self, $c) = @_;
{indent}    return $c->session->{'{'SiteName'}{'} || 'default';
{indent}}}

{indent}sub _schema {{
{indent}    my ($self, $c) = @_;
{indent}    require Comserv::Util::ModelCatalog;
{indent}    return Comserv::Util::ModelCatalog->get_model($c);
{indent}}}'''
        
        content = content[:match.start()] + helper_functions + content[match.end():]

# Write back to file
with open(file_path, 'w') as f:
    f.write(content)

print("Inventory.pm fixed successfully!")
