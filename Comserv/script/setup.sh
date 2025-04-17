#!/bin/bash

# Clone the Git repository
git clone https://github.com/your-repo/comserv.git

# Change to the repository directory
cd comserv

# Install dependencies using cpanfile
cpanm --installdeps .

# Run the application
script/comserv_server.pl