#!/usr/bin/env python3

file_path = "../lib/Comserv/Controller/Inventory.pm"

with open(file_path, 'r') as f:
    lines = f.readlines()

# Find the Helpers section
helpers_start = None
for i, line in enumerate(lines):
    if line.strip() == "# -------------------------------------------------------------------------" and i + 2 < len(lines) and lines[i + 1].strip() == "# Helpers" and lines[i + 2].strip() == "# -------------------------------------------------------------------------":
        helpers_start = i + 3
        break

if helpers_start is not None:
    # Insert helper functions after the Helpers header
    helper_functions = [
        "sub _sitename {\n",
        "    my ($self, $c) = @_;\n",
        "    return $c->session->{'SiteName'} || 'default';\n",
        "}\n",
        "\n",
        "sub _schema {\n",
        "    my ($self, $c) = @_;\n",
        "    require Comserv::Util::ModelCatalog;\n",
        "    return Comserv::Util::ModelCatalog->get_model($c);\n",
        "}\n",
        "\n"
    ]
    
    # Find where to insert (after the empty lines after Helpers header)
    insert_pos = helpers_start
    while insert_pos < len(lines) and lines[insert_pos].strip() == '':
        insert_pos += 1
    
    # Insert the helper functions
    for helper in reversed(helper_functions):
        lines.insert(insert_pos, helper)
    
    # Fix the auto method
    for i, line in enumerate(lines):
        if 'my $email_navigation = $c->navigation;' in line:
            # Find the end of this block
            end_pos = i
            while end_pos < len(lines) and '}' not in lines[end_pos]:
                end_pos += 1
            
            # Replace the block
            replacement = '''    # Navigation setup moved to comserv_navigation plugin integration
    # Email configuration navigation is automatically handled through Comserv's navigation system
    # See Comserv::Util::ModelCatalog for navigation configuration
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto',
        'Email navigation setup deferred to Comserv navigation system');'''
            
            # Replace the lines
            del lines[i:end_pos + 1]
            lines.insert(i, replacement + '\n')
            break

    # Write back to file
    with open(file_path, 'w') as f:
        f.writelines(lines)
    
    print("Inventory.pm fixed successfully!")
else:
    print("Could not find Helpers section in file.")
