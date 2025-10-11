# Database Connection Configuration Guide

## Overview

This document explains how to properly configure database connections in the Comserv application. It includes information about the correct DSN (Data Source Name) format for MySQL connections and how to troubleshoot common connection issues.

## Database Configuration File

The database configuration is stored in `db_config.json` in the root directory of the application. This file contains connection details for all databases used by the application.

### Required Fields

Each database connection requires the following fields:

- `db_type`: The database driver type (e.g., "mysql")
- `host`: The database server hostname or IP address
- `port`: The database server port
- `username`: The database username
- `password`: The database password
- `database`: The name of the database to connect to

### Example Configuration

```json
{
    "shanta_ency": {
        "db_type": "mysql",
        "host": "localhost",
        "port": 3306,
        "username": "db_user",
        "password": "db_password",
        "database": "ency"
    },
    "shanta_forager": {
        "db_type": "mysql",
        "host": "localhost",
        "port": 3306,
        "username": "db_user",
        "password": "db_password",
        "database": "shanta_forager"
    },
    "remote_connections": {
        "local_ency": {
            "db_type": "mysql",
            "host": "localhost",
            "port": 3306,
            "username": "db_user",
            "password": "db_password",
            "database": "ency"
        }
    }
}
```

## DSN Format for MySQL

The correct DSN format for MySQL connections is:

```
dbi:mysql:database=DATABASE_NAME;host=HOST;port=PORT
```

This format is used in the following files:
- `Comserv/lib/Comserv/Model/DBEncy.pm`
- `Comserv/lib/Comserv/Model/DBForager.pm`
- `Comserv/lib/Comserv/Model/RemoteDB.pm`
- `Comserv/lib/Comserv/Model/DBSchemaManager.pm`

## Common Connection Issues

### Missing db_type Field

If the `db_type` field is missing from the configuration, you may see an error like:

```
DBI Connection failed: Can't connect to data source 'dbi::dbname=ency;host=localhost;port=3306' because I can't work out what driver to use
```

**Solution**: Add the `db_type` field with value "mysql" to your database configuration.

### Incorrect DSN Format

If the DSN format is incorrect, you may see errors related to connection failures.

**Solution**: Ensure the DSN format follows the pattern shown above.

### Database Access Permissions

If the database user doesn't have the necessary permissions, you may see access denied errors.

**Solution**: Check that the database user has the appropriate permissions for the database.

## Testing Database Connections

You can test database connections using the following Perl command:

```perl
perl -MDBI -e 'DBI->connect("dbi:mysql:database=ency;host=localhost;port=3306", "username", "password") or die $DBI::errstr'
```

Replace the connection details with your actual database information.

## Support

For additional help with database connection issues, please contact the system administrator.