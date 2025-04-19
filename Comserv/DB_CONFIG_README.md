# Database Configuration

## Quick Setup

1. Place `db_config.json` in the Comserv application root directory
2. OR set environment variable: `export COMSERV_CONFIG_PATH=/path/to/config/dir`

## Configuration File Location

The system will look for `db_config.json` in:
1. Directory specified by `COMSERV_CONFIG_PATH` environment variable (if set)
2. Comserv application root directory (default fallback)

## Example Configuration

```json
{
  "shanta_ency": {
    "database": "ency_db_name",
    "host": "db_host",
    "port": 3306,
    "username": "db_user",
    "password": "db_password"
  },
  "shanta_forager": {
    "database": "forager_db_name",
    "host": "db_host",
    "port": 3306,
    "username": "db_user",
    "password": "db_password"
  }
}
```

## Important Notes

- NEVER use hardcoded absolute paths to `db_config.json`
- Keep database credentials secure
- Do not commit `db_config.json` to version control
- Ensure proper file permissions

## Running the Application

Use the provided script to automatically set up the environment:
```
cd /path/to/Comserv
./run_app.sh
```