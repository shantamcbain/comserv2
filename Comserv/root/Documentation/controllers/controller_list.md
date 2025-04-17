# Controller Documentation Status

This document lists all controllers in the Comserv application and their documentation status.

## Controllers

| Controller | Documentation Status | Path |
|------------|---------------------|------|
| 3d | ❌ Missing | `/lib/Comserv/Controller/3d.pm` |
| Admin | ❌ Missing | `/lib/Comserv/Controller/Admin.pm` |
| Admin/Theme | ❌ Missing | `/lib/Comserv/Controller/Admin/Theme.pm` |
| Apiary | ❌ Missing | `/lib/Comserv/Controller/Apiary.pm` |
| Base | ❌ Missing | `/lib/Comserv/Controller/Base.pm` |
| BMaster | ❌ Missing | `/lib/Comserv/Controller/BMaster.pm` |
| CSC | ❌ Missing | `/lib/Comserv/Controller/CSC.pm` |
| Documentation | ✅ Documented | `/lib/Comserv/Controller/Documentation.pm` |
| Documentation/Config | ❌ Missing | `/lib/Comserv/Controller/Documentation/Config.pm` |
| Documentation/ConfigBased | ❌ Missing | `/lib/Comserv/Controller/Documentation/ConfigBased.pm` |
| Documentation/ScanMethods | ❌ Missing | `/lib/Comserv/Controller/Documentation/ScanMethods.pm` |
| ENCY | ❌ Missing | `/lib/Comserv/Controller/ENCY.pm` |
| File | ❌ Missing | `/lib/Comserv/Controller/File.pm` |
| Forager | ❌ Missing | `/lib/Comserv/Controller/Forager.pm` |
| Hosting | ❌ Missing | `/lib/Comserv/Controller/Hosting.pm` |
| Log | ❌ Missing | `/lib/Comserv/Controller/Log.pm` |
| Mail | ❌ Missing | `/lib/Comserv/Controller/Mail.pm` |
| MCoop | ❌ Missing | `/lib/Comserv/Controller/MCoop.pm` |
| Project | ❌ Missing | `/lib/Comserv/Controller/Project.pm` |
| Proxmox | ❌ Missing | `/lib/Comserv/Controller/Proxmox.pm` |
| ProxmoxServers | ❌ Missing | `/lib/Comserv/Controller/ProxmoxServers.pm` |
| Root | ✅ Documented | `/lib/Comserv/Controller/Root.pm` |
| Site | ❌ Missing | `/lib/Comserv/Controller/Site.pm` |
| TestRoute | ❌ Missing | `/lib/Comserv/Controller/TestRoute.pm` |
| ThemeAdmin | ❌ Missing | `/lib/Comserv/Controller/ThemeAdmin.pm` |
| ThemeAdmin/update_theme_with_variables | ❌ Missing | `/lib/Comserv/Controller/ThemeAdmin/update_theme_with_variables.pm` |
| ThemeEditor | ❌ Missing | `/lib/Comserv/Controller/ThemeEditor.pm` |
| ThemeTest | ❌ Missing | `/lib/Comserv/Controller/ThemeTest.pm` |
| Todo | ❌ Missing | `/lib/Comserv/Controller/Todo.pm` |
| USBM | ❌ Missing | `/lib/Comserv/Controller/USBM.pm` |
| User | ✅ Documented | `/lib/Comserv/Controller/User.pm` |
| Ve7tit | ❌ Missing | `/lib/Comserv/Controller/Ve7tit.pm` |
| Voip | ❌ Missing | `/lib/Comserv/Controller/Voip.pm` |
| WorkShop | ❌ Missing | `/lib/Comserv/Controller/WorkShop.pm` |

## How to Add Documentation

To add documentation for a controller:

1. Create a Markdown file in the `/root/Documentation/controllers/` directory
2. Name the file after the controller (e.g., `Root.md` for the Root controller)
3. Include the following sections:
   - Overview
   - Key Features
   - Methods
   - Access Control
   - Related Files

## Documentation Template

```markdown
# [Controller Name] Controller

## Overview
Brief description of the controller's purpose.

## Key Features
- Feature 1
- Feature 2
- Feature 3

## Methods
- `method1`: Description
- `method2`: Description
- `method3`: Description

## Access Control
This controller is accessible to users with the following roles:
- role1
- role2

## Related Files
- Related file 1
- Related file 2
```