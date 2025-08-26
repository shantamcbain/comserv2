#!/bin/bash

# Make all scripts in the script directory executable
cd "$(dirname "$0")"
chmod +x *.pl
chmod +x *.sh

echo "All scripts are now executable."