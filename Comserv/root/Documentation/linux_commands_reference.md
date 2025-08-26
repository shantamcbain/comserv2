# Linux Commands Reference

**Last Updated:** May 31, 2025  
**Author:** Shanta  
**Status:** Active

## Overview

The Linux Commands Reference is a comprehensive guide to common Linux commands for system administrators and developers. This documentation provides detailed information about the most frequently used Linux commands, their options, and examples of how to use them.

## Accessing the Linux Commands Reference

The Linux Commands Reference can be accessed through the HelpDesk Knowledge Base:

1. Navigate to the HelpDesk by clicking on the "HelpDesk" link in the main navigation menu
2. Click on the "Knowledge Base" button
3. In the Knowledge Base, find the "System Administration" category
4. Click on the "Linux Commands Reference" link

Alternatively, you can access the reference directly at:
`/HelpDesk/kb/linux_commands`

## Command Categories

The Linux Commands Reference is organized into the following categories:

1. **File System Commands**: Commands for navigating and managing the file system
   - `ls` - List directory contents
   - `cd` - Change directory
   - `pwd` - Print working directory
   - `mkdir` - Make directory
   - `rmdir` - Remove directory
   - `find` - Search for files

2. **File Operations**: Commands for working with files
   - `cp` - Copy files and directories
   - `mv` - Move or rename files
   - `rm` - Remove files or directories
   - `touch` - Create empty files or update timestamps

3. **Text Processing**: Commands for processing and analyzing text
   - `cat` - Concatenate and display file contents
   - `less` - View file contents with pagination
   - `head` - Display the beginning of a file
   - `tail` - Display the end of a file
   - `grep` - Search for patterns in files
   - `sed` - Stream editor for filtering and transforming text
   - `awk` - Pattern scanning and processing language

4. **System Information**: Commands for viewing system information
   - `uname` - Print system information
   - `df` - Report file system disk space usage
   - `du` - Estimate file space usage
   - `free` - Display amount of free and used memory
   - `top` - Display Linux processes
   - `htop` - Interactive process viewer

5. **Process Management**: Commands for managing processes
   - `ps` - Report process status
   - `kill` - Terminate processes
   - `bg` - Put jobs in background
   - `fg` - Bring jobs to foreground
   - `jobs` - List active jobs
   - `nohup` - Run command immune to hangups

6. **User Management**: Commands for managing users
   - `useradd` - Create a new user
   - `usermod` - Modify user account
   - `userdel` - Delete a user account
   - `passwd` - Change user password
   - `who` - Show who is logged in
   - `id` - Print user and group information

7. **Networking**: Commands for networking operations
   - `ping` - Send ICMP ECHO_REQUEST to network hosts
   - `ifconfig` - Configure network interface
   - `ip` - Show/manipulate routing, devices, policy routing and tunnels
   - `netstat` - Print network connections, routing tables, interface statistics
   - `ss` - Another utility to investigate sockets
   - `wget` - Non-interactive network downloader
   - `curl` - Transfer data from or to a server

8. **Package Management**: Commands for managing packages
   - `apt` - Advanced Package Tool (Debian/Ubuntu)
   - `yum` - Yellowdog Updater Modified (RHEL/CentOS/Fedora)
   - `dnf` - Dandified YUM (Fedora/RHEL 8+)

9. **Permissions**: Commands for managing file permissions
   - `chmod` - Change file mode bits
   - `chown` - Change file owner and group
   - `chgrp` - Change group ownership

10. **Compression**: Commands for compressing and archiving files
    - `tar` - Tape archive
    - `gzip` - Compress or expand files
    - `zip` - Package and compress files

## Command Format

Each command in the reference is presented with:

1. **Command Name**: The name of the command
2. **Description**: A brief description of what the command does
3. **Examples**: Common usage examples with explanations
4. **Notes and Warnings**: Important information about using the command

## Use Cases

The Linux Commands Reference is particularly useful for:

1. **System Administrators**: Managing servers and systems
2. **Developers**: Working with Linux development environments
3. **DevOps Engineers**: Automating deployment and infrastructure
4. **IT Support Staff**: Troubleshooting Linux-based systems
5. **Students**: Learning Linux system administration

## Related Documentation

- [Server Maintenance Guide](#) - Guide to maintaining Linux servers
- [Backup and Recovery](#) - Procedures for backing up and recovering Linux systems
- [Security Best Practices](#) - Security recommendations for Linux systems

## Feedback and Contributions

If you have suggestions for improving the Linux Commands Reference or would like to contribute additional commands or examples, please contact the documentation team through the HelpDesk contact form.

## Implementation Details

The Linux Commands Reference is implemented as a Template Toolkit (.tt) file that is rendered by the HelpDesk controller. The controller provides a dedicated route for accessing the reference:

```perl
sub linux_commands :Chained('base') :PathPart('kb/linux_commands') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'linux_commands', 
        "Starting linux_commands action");
    
    $c->stash(
        template => 'CSC/HelpDesk/linux_commands.tt',
        title => 'Linux Commands Reference'
    );
    
    # Push debug message to stash
    push @{$c->stash->{debug_msg}}, "Linux Commands Reference loaded";
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'linux_commands', 
        "Completed linux_commands action");
    
    # Explicitly forward to the TT view
    $c->forward($c->view('TT'));
}
```

The template file (`linux_commands.tt`) contains detailed information about each command, formatted with HTML and CSS for optimal readability.