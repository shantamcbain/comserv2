# Comserv Project Information

## Summary
Comserv is a comprehensive web-based system for managing business operations, projects, and documentation. It's built using the Catalyst Perl web framework and provides features for project management, theme customization, and user authentication.

## Structure
- `Comserv/`: Main application directory containing the core application code
  - `lib/`: Application code and models
  - `docs/`: Documentation files
  - `root/`: Static assets and templates
  - `script/`: Utility scripts for server management and database operations
  - `t/`: Test files
- `app/`: Additional application components
- `data/`: Data files including pricing information
- `proxmox/`: Proxmox VE integration components

## Language & Runtime
**Language**: Perl
**Version**: 5.x (compatible with Perl 5.40.0)
**Framework**: Catalyst 5.90130
**Build System**: Module::Install
**Package Manager**: CPAN

## Dependencies
**Main Dependencies**:
- Catalyst::Runtime (5.90130)
- Moose
- DBIx::Class
- Template (Template Toolkit)
- JSON/JSON::MaybeXS
- Log::Log4perl
- DateTime
- File::Slurp

**Development Dependencies**:
- Test::More (0.88+)
- Test::Pod
- Test::Pod::Coverage
- Test::WWW::Mechanize::Catalyst
- Catalyst::Devel

## Build & Installation
```bash
cd Comserv
perl Makefile.PL
make
make test
make install
```

## Database
**Type**: MySQL
**Setup**: 
```bash
mysql -u root -p < database_initialization_script.sql
```
**Schema Management**: DBIx::Class::Schema::Loader

## Testing
**Framework**: Test::More
**Test Location**: Comserv/t/
**Run Command**:
```bash
cd Comserv
prove -l t/
```

## Server Execution
**Development Server**:
```bash
cd Comserv
script/comserv_server.pl
```
**Production Deployment**:
```bash
cd Comserv
script/comserv_fastcgi.pl
# or
starman --port 5000 --workers 5 comserv.psgi
```

## Authentication & Authorization
- Session-based authentication
- Role-based access control
- Multiple authentication realms
- Support for user groups and site-specific permissions

## Features
- Project management system
- Theme customization system
- Email integration
- PDF generation
- Proxmox VE integration
- Multi-site support