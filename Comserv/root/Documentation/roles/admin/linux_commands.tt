# Linux Commands Reference

**Last Updated:** June 21, 2024  
**Author:** Shanta  
**Status:** Active

## Overview

This document provides a reference guide for common Linux commands that administrators may need when managing Ubuntu, Debian, and Proxmox systems. These commands are useful for day-to-day administration tasks, troubleshooting, and system maintenance.

## Table of Contents

- [System Information](#system-information)
- [Hardware Information](#hardware-information)
- [File System Operations](#file-system-operations)
- [Process Management](#process-management)
- [Package Management](#package-management)
- [Network Commands](#network-commands)
- [Service Management](#service-management)
- [User Management](#user-management)
- [File Searching](#file-searching)
- [Disk Management](#disk-management)
- [Proxmox Management](#proxmox-management)
- [Log Files](#log-files)
- [Compression and Archiving](#compression-and-archiving)
- [System Monitoring](#system-monitoring)
- [Firewall Management](#firewall-management)
- [Troubleshooting](#troubleshooting)
- [Server Room Management](#server-room-management)
- [Best Practices](#best-practices)

## System Information

<details>
<summary><strong>System and Kernel Information</strong> (Click to expand)</summary>

<div class="command-card">
<h4>uname - Print system information</h4>

```bash
# Display all system information (kernel name, hostname, kernel version, etc.)
uname -a
```

**Example output:**
```
Linux workstation 6.11.0-24-generic #24-Ubuntu SMP PREEMPT_DYNAMIC Tue Jun 4 17:42:05 UTC 2024 x86_64 x86_64 x86_64 GNU/Linux
```

**Usage notes:**
- `-a` shows all information
- `-r` shows only kernel release
- `-n` shows only hostname
- `-m` shows only machine hardware name
- Available on all Linux distributions
</div>

<div class="command-card">
<h4>lsb_release - Display Linux Standard Base information</h4>

```bash
# Show distribution information
lsb_release -a
```

**Example output:**
```
No LSB modules are available.
Distributor ID: Ubuntu
Description:    Ubuntu 24.04 LTS
Release:        24.04
Codename:       noble
```

**Usage notes:**
- `-a` shows all information
- `-d` shows only description
- `-r` shows only release number
- May not be installed by default on minimal installations
- Install with: `sudo apt install lsb-release`
</div>

<div class="command-card">
<h4>cat /etc/os-release - Show OS information</h4>

```bash
# Show detailed OS version information
cat /etc/os-release
```

**Example output:**
```
PRETTY_NAME="Ubuntu 24.04 LTS"
NAME="Ubuntu"
VERSION_ID="24.04"
VERSION="24.04 LTS (Noble Numbat)"
VERSION_CODENAME=noble
ID=ubuntu
ID_LIKE=debian
HOME_URL="https://www.ubuntu.com/"
SUPPORT_URL="https://help.ubuntu.com/"
BUG_REPORT_URL="https://bugs.launchpad.net/ubuntu/"
PRIVACY_POLICY_URL="https://www.ubuntu.com/legal/terms-and-policies/privacy-policy"
UBUNTU_CODENAME=noble
```

**Usage notes:**
- Available on all modern Linux distributions
- More reliable than `lsb_release` as it's always present
- Contains detailed information about the OS
</div>

<div class="command-card">
<h4>hostname - Show or set system hostname</h4>

```bash
# Display the system hostname
hostname

# Display the FQDN (Fully Qualified Domain Name)
hostname -f

# Set a new hostname (temporary, until reboot)
sudo hostname new-hostname
```

**Usage notes:**
- To permanently change hostname, edit `/etc/hostname`
- After editing, run: `sudo systemctl restart systemd-hostnamed`
- Available on all Linux distributions
</div>

<div class="command-card">
<h4>uptime - Show system uptime</h4>

```bash
# Show how long the system has been running
uptime
```

**Example output:**
```
 14:23:32 up 3 days, 2:57, 5 users, load average: 0.52, 0.58, 0.59
```

**Usage notes:**
- Shows current time, uptime, number of users, and load averages
- Load averages represent system load over 1, 5, and 15 minutes
- Available on all Linux distributions
</div>

<div class="command-card">
<h4>w - Show who is logged on and what they are doing</h4>

```bash
# Display information about currently logged-in users
w
```

**Example output:**
```
 14:25:02 up 3 days,  2:59,  5 users,  load average: 0.35, 0.54, 0.57
USER     TTY      FROM             LOGIN@   IDLE   JCPU   PCPU WHAT
shanta   tty7     :0               Mon08   3days  1:23m  0.05s /usr/libexec/gnome-session-binary
shanta   pts/0    :0               14:20    0.00s  0.05s  0.00s w
```

**Usage notes:**
- Shows detailed information about logged-in users
- Displays login time, idle time, and current activity
- Available on all Linux distributions
</div>
</details>

## Hardware Information

<details>
<summary><strong>CPU, Memory, and Device Information</strong> (Click to expand)</summary>

<div class="command-card">
<h4>lscpu - Display CPU information</h4>

```bash
# Display detailed CPU information
lscpu
```

**Example output:**
```
Architecture:            x86_64
  CPU op-mode(s):        32-bit, 64-bit
  Address sizes:         39 bits physical, 48 bits virtual
  Byte Order:            Little Endian
CPU(s):                  8
  On-line CPU(s) list:   0-7
Vendor ID:               GenuineIntel
  Model name:            Intel(R) Core(TM) i7-10700 CPU @ 2.90GHz
```

**Usage notes:**
- Shows CPU architecture, cores, model, cache sizes, etc.
- Part of the `util-linux` package, available on all distributions
- For a summary, use: `lscpu | grep -E '^CPU\(s\)|^Model name'`
</div>

<div class="command-card">
<h4>free - Display memory usage</h4>

```bash
# Display memory usage in human-readable format
free -h

# Update continuously every 2 seconds
free -h -s 2
```

**Example output:**
```
               total        used        free      shared  buff/cache   available
Mem:            15Gi       4.8Gi       5.9Gi       264Mi       4.8Gi        10Gi
Swap:          2.0Gi          0B       2.0Gi
```

**Usage notes:**
- `-h` shows sizes in human-readable format (GB, MB)
- `-s` followed by seconds will update continuously
- `available` column shows memory available for new applications
- Available on all Linux distributions
</div>

<div class="command-card">
<h4>df - Report file system disk space usage</h4>

```bash
# Display disk usage in human-readable format
df -h

# Display disk usage including file system type
df -hT
```

**Example output:**
```
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p2  457G  112G  322G  26% /
/dev/nvme0n1p1  511M  5.3M  506M   2% /boot/efi
```

**Usage notes:**
- `-h` shows sizes in human-readable format
- `-T` shows file system type (ext4, xfs, etc.)
- `-i` shows inode usage instead of block usage
- Available on all Linux distributions
</div>

<div class="command-card">
<h4>lsblk - List block devices</h4>

```bash
# List information about all block devices
lsblk

# Show more detailed information
lsblk -f
```

**Example output:**
```
NAME        MAJ:MIN RM   SIZE RO TYPE MOUNTPOINTS
nvme0n1     259:0    0 476.9G  0 disk 
├─nvme0n1p1 259:1    0   512M  0 part /boot/efi
└─nvme0n1p2 259:2    0 476.4G  0 part /
```

**Usage notes:**
- Shows disk partitions, sizes, and mount points
- `-f` shows file system type, UUID, and label
- Part of the `util-linux` package, available on all distributions
</div>

<div class="command-card">
<h4>lspci - List PCI devices</h4>

```bash
# List all PCI devices
lspci

# Show detailed information
lspci -v
```

**Example output:**
```
00:00.0 Host bridge: Intel Corporation Device 9b43 (rev 05)
00:02.0 VGA compatible controller: Intel Corporation CometLake-S GT2 [UHD Graphics 630] (rev 05)
```

**Usage notes:**
- Shows graphics cards, network adapters, and other PCI devices
- `-v` shows more detailed information
- `-k` shows kernel drivers handling each device
- Install with: `sudo apt install pciutils` if not available
</div>

<div class="command-card">
<h4>lsusb - List USB devices</h4>

```bash
# List all USB devices
lsusb

# Show detailed information
lsusb -v
```

**Example output:**
```
Bus 002 Device 001: ID 1d6b:0003 Linux Foundation 3.0 root hub
Bus 001 Device 003: ID 046d:c52b Logitech, Inc. Unifying Receiver
```

**Usage notes:**
- Shows USB devices like keyboards, mice, webcams, etc.
- `-v` shows detailed information (verbose)
- `-t` shows devices in a tree format
- Install with: `sudo apt install usbutils` if not available
</div>

<div class="command-card">
<h4>lshw - List hardware</h4>

```bash
# Display detailed hardware information
sudo lshw

# Display information in a more readable format
sudo lshw -short

# Display information about a specific hardware class
sudo lshw -C network
```

**Example output (short format):**
```
H/W path         Device      Class       Description
=================================================
                             system      Computer
/0                           bus         Motherboard
/0/0                         processor   Intel(R) Core(TM) i7-10700 CPU @ 2.90GHz
/0/0/0                       memory      128KiB L1 cache
```

**Usage notes:**
- Provides comprehensive hardware information
- Requires sudo for complete information
- `-C` followed by class name shows specific hardware (network, disk, etc.)
- May not be installed by default, install with: `sudo apt install lshw`
</div>

<div class="command-card">
<h4>inxi - System information script</h4>

```bash
# Display system information
inxi -F

# Display only CPU information
inxi -C
```

**Example output:**
```
CPU: 8-core Intel Core i7-10700 (-MT MCP-) speed/min/max: 2900/800/4800 MHz
Graphics: Device-1: Intel CometLake-S GT2 [UHD Graphics 630] driver: i915 v: kernel
Display: x11 server: X.Org v: 21.1.8 driver: X: loaded: modesetting dri: iris
Network: Device-1: Intel Ethernet I219-V driver: e1000e
```

**Usage notes:**
- Provides a comprehensive system summary
- Not installed by default, install with: `sudo apt install inxi`
- `-F` shows full information
- Has specific flags for different hardware components (-C for CPU, -G for graphics, etc.)
</div>
</details>

## File System Operations

### Navigation and File Management

```bash
# List files and directories
ls -la

# Change directory
cd /path/to/directory

# Print working directory
pwd

# Create a directory
mkdir directory_name

# Create nested directories
mkdir -p parent/child/grandchild

# Remove a file
rm filename

# Remove a directory
rmdir directory_name

# Remove a directory and its contents
rm -rf directory_name

# Copy a file
cp source destination

# Copy a directory and its contents
cp -r source_directory destination_directory

# Move/rename a file or directory
mv source destination

# Create a symbolic link
ln -s target_path link_name
```

### File Viewing and Editing

```bash
# View file contents
cat filename

# View file with pagination
less filename

# View the beginning of a file
head filename

# View the end of a file
tail filename

# Follow the end of a file (useful for logs)
tail -f /var/log/syslog

# Edit a file with nano (beginner-friendly)
nano filename

# Edit a file with vim
vim filename
```

### File Permissions

```bash
# Change file permissions
chmod 755 filename

# Change file owner
chown user:group filename

# Change ownership recursively
chown -R user:group directory

# Set default permissions for new files
umask 022
```

## Process Management

```bash
# Display running processes
ps aux

# Display process tree
pstree

# Interactive process viewer
top

# Enhanced interactive process viewer
htop

# Kill a process by ID
kill PID

# Kill a process by name
pkill process_name

# Force kill a process
kill -9 PID

# Run a process in the background
command &

# List background jobs
jobs

# Bring a background job to the foreground
fg %job_number
```

## Package Management

### APT (Ubuntu/Debian)

```bash
# Update package lists
sudo apt update

# Upgrade installed packages
sudo apt upgrade

# Update package lists and upgrade installed packages
sudo apt update && sudo apt upgrade -y

# Install a package
sudo apt install package_name

# Remove a package
sudo apt remove package_name

# Remove a package and its configuration files
sudo apt purge package_name

# Search for a package
apt search keyword

# Show package information
apt show package_name

# List installed packages
apt list --installed

# Clean up package cache
sudo apt clean

# Remove unused dependencies
sudo apt autoremove
```

### DPKG (Debian Package Manager)

```bash
# Install a .deb package file
sudo dpkg -i package.deb

# List installed packages
dpkg -l

# Show information about an installed package
dpkg -s package_name

# List files installed by a package
dpkg -L package_name
```

## Network Commands

<details>
<summary><strong>Network Interface Commands</strong> (Click to expand)</summary>

<div class="command-card">
<h4>ip - Show/manipulate routing, network devices, interfaces and tunnels</h4>

```bash
# Display all network interfaces with addresses
ip a

# Display specific interface information
ip a show eth0

# Display link status of interfaces
ip link

# Set interface up/down
sudo ip link set eth0 up
sudo ip link set eth0 down

# Add/remove IP address to interface
sudo ip addr add 192.168.1.10/24 dev eth0
sudo ip addr del 192.168.1.10/24 dev eth0
```

**Example output:**
```
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
       valid_lft forever preferred_lft forever
2: enp0s31f6: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP group default qlen 1000
    link/ether 00:1f:c6:9c:7a:b2 brd ff:ff:ff:ff:ff:ff
    inet 192.168.1.100/24 brd 192.168.1.255 scope global dynamic noprefixroute enp0s31f6
       valid_lft 86389sec preferred_lft 86389sec
```

**Usage notes:**
- Modern replacement for `ifconfig`
- Available on all current Linux distributions
- More powerful and flexible than `ifconfig`
- Part of the `iproute2` package
</div>

<div class="command-card">
<h4>ifconfig - Configure network interface (legacy command)</h4>

```bash
# Display all network interfaces
ifconfig

# Display specific interface
ifconfig eth0

# Set interface up/down
sudo ifconfig eth0 up
sudo ifconfig eth0 down

# Assign IP address to interface
sudo ifconfig eth0 192.168.1.10 netmask 255.255.255.0
```

**Example output:**
```
enp0s31f6: flags=4163<UP,BROADCAST,RUNNING,MULTICAST>  mtu 1500
        inet 192.168.1.100  netmask 255.255.255.0  broadcast 192.168.1.255
        inet6 fe80::21f:c6ff:fe9c:7ab2  prefixlen 64  scopeid 0x20<link>
        ether 00:1f:c6:9c:7a:b2  txqueuelen 1000  (Ethernet)
        RX packets 8935762  bytes 12874892886 (12.8 GB)
        RX errors 0  dropped 0  overruns 0  frame 0
        TX packets 4543051  bytes 601736092 (601.7 MB)
        TX errors 0  dropped 0 overruns 0  carrier 0  collisions 0
```

**Usage notes:**
- Legacy command, not installed by default on newer systems
- Install with: `sudo apt install net-tools`
- Use `ip` command instead on modern systems
- Still commonly used in scripts and documentation
</div>

<div class="command-card">
<h4>nmcli - NetworkManager command-line tool</h4>

```bash
# Show all connections
nmcli connection show

# Show active connections
nmcli connection show --active

# Show device status
nmcli device status

# Connect to a WiFi network
nmcli device wifi connect SSID_NAME password PASSWORD

# Create a new connection
nmcli connection add type ethernet con-name "My Connection" ifname eth0
```

**Example output:**
```
NAME                UUID                                  TYPE      DEVICE    
Wired connection 1  8a7e034f-6a50-3c7b-9123-0d0ff8c5f503  ethernet  enp0s31f6 
```

**Usage notes:**
- Modern tool for managing NetworkManager connections
- Available on most desktop Linux distributions
- More user-friendly than direct configuration files
- Handles WiFi, Ethernet, VPN, and other connection types
</div>

<div class="command-card">
<h4>netplan - Network configuration tool for Ubuntu</h4>

```bash
# Apply network configuration
sudo netplan apply

# Generate configuration from /etc/netplan/*.yaml
sudo netplan generate

# Try configuration without applying
sudo netplan try
```

**Configuration example (/etc/netplan/01-netcfg.yaml):**
```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    enp0s31f6:
      dhcp4: true
```

**Usage notes:**
- Default network configuration system on Ubuntu 18.04+
- Uses YAML configuration files in `/etc/netplan/`
- Generates either systemd-networkd or NetworkManager configuration
- Not available on non-Ubuntu systems
</div>
</details>

<details>
<summary><strong>Routing and Connectivity</strong> (Click to expand)</summary>

<div class="command-card">
<h4>ip route - Show/manipulate routing table</h4>

```bash
# Display routing table
ip route

# Add static route
sudo ip route add 192.168.2.0/24 via 192.168.1.1

# Delete route
sudo ip route del 192.168.2.0/24

# Add default gateway
sudo ip route add default via 192.168.1.1
```

**Example output:**
```
default via 192.168.1.1 dev enp0s31f6 proto dhcp metric 100 
169.254.0.0/16 dev enp0s31f6 scope link metric 1000 
192.168.1.0/24 dev enp0s31f6 proto kernel scope link src 192.168.1.100 metric 100 
```

**Usage notes:**
- Modern replacement for `route` command
- Available on all current Linux distributions
- Part of the `iproute2` package
</div>

<div class="command-card">
<h4>route - Show/manipulate IP routing table (legacy command)</h4>

```bash
# Display routing table
route -n

# Add static route
sudo route add -net 192.168.2.0 netmask 255.255.255.0 gw 192.168.1.1

# Delete route
sudo route del -net 192.168.2.0 netmask 255.255.255.0

# Add default gateway
sudo route add default gw 192.168.1.1
```

**Example output:**
```
Kernel IP routing table
Destination     Gateway         Genmask         Flags Metric Ref    Use Iface
0.0.0.0         192.168.1.1     0.0.0.0         UG    100    0        0 enp0s31f6
169.254.0.0     0.0.0.0         255.255.0.0     U     1000   0        0 enp0s31f6
192.168.1.0     0.0.0.0         255.255.255.0   U     100    0        0 enp0s31f6
```

**Usage notes:**
- Legacy command, not installed by default on newer systems
- Install with: `sudo apt install net-tools`
- Use `ip route` instead on modern systems
</div>

<div class="command-card">
<h4>ping - Send ICMP ECHO_REQUEST to network hosts</h4>

```bash
# Basic ping
ping google.com

# Limit to specific number of packets
ping -c 4 google.com

# Specify interval between packets (in seconds)
ping -i 2 google.com

# Ping with larger packet size
ping -s 1500 google.com
```

**Example output:**
```
PING google.com (142.250.185.78) 56(84) bytes of data.
64 bytes from muc11s18-in-f14.1e100.net (142.250.185.78): icmp_seq=1 ttl=118 time=10.8 ms
64 bytes from muc11s18-in-f14.1e100.net (142.250.185.78): icmp_seq=2 ttl=118 time=10.7 ms
64 bytes from muc11s18-in-f14.1e100.net (142.250.185.78): icmp_seq=3 ttl=118 time=10.9 ms
```

**Usage notes:**
- Available on all Linux distributions
- Useful for testing basic network connectivity
- Press Ctrl+C to stop continuous pinging
- Some networks block ICMP packets, so ping may not work everywhere
</div>

<div class="command-card">
<h4>traceroute - Print the route packets trace to network host</h4>

```bash
# Trace route to host
traceroute google.com

# Use TCP SYN for probes
traceroute -T google.com

# Specify number of probes per hop
traceroute -q 1 google.com
```

**Example output:**
```
traceroute to google.com (142.250.185.78), 30 hops max, 60 byte packets
 1  _gateway (192.168.1.1)  0.226 ms  0.271 ms  0.305 ms
 2  10.0.0.1 (10.0.0.1)  10.432 ms  10.468 ms  10.501 ms
 3  * * *
 4  * * *
 5  142.250.185.78 (142.250.185.78)  10.765 ms  10.798 ms  10.830 ms
```

**Usage notes:**
- May not be installed by default, install with: `sudo apt install traceroute`
- Alternative: `mtr` (My Traceroute) combines ping and traceroute
- Some networks block traceroute packets
- Asterisks (*) indicate no response from that hop
</div>

<div class="command-card">
<h4>mtr - Network diagnostic tool combining ping and traceroute</h4>

```bash
# Run mtr in terminal mode
mtr google.com

# Generate a report (10 packets per hop)
mtr --report -c 10 google.com

# Use TCP instead of ICMP
mtr --tcp google.com
```

**Example output:**
```
                                       My traceroute  [v0.95]
workstation (192.168.1.100)                                   2024-06-21T15:12:32+0200
Keys:  Help   Display mode   Restart statistics   Order of fields   quit
                                           Packets               Pings
 Host                                    Loss%   Snt   Last   Avg  Best  Wrst StDev
 1. _gateway                              0.0%    10    0.3   0.3   0.3   0.4   0.0
 2. 10.0.0.1                              0.0%    10   10.4  10.5  10.3  10.7   0.1
 3. ???                                  100.0    10    0.0   0.0   0.0   0.0   0.0
 4. ???                                  100.0    10    0.0   0.0   0.0   0.0   0.0
 5. muc11s18-in-f14.1e100.net             0.0%    10   10.8  10.8  10.7  11.0   0.1
```

**Usage notes:**
- May not be installed by default, install with: `sudo apt install mtr`
- More informative than traceroute alone
- Shows packet loss and latency statistics
- Run with sudo for more accurate results
</div>
</details>

<details>
<summary><strong>Network Diagnostics and DNS</strong> (Click to expand)</summary>

<div class="command-card">
<h4>netstat - Network statistics (legacy command)</h4>

```bash
# Display all listening TCP and UDP ports
netstat -tuln

# Display all connections with process information
sudo netstat -tulpn

# Display routing table
netstat -r

# Display network interface statistics
netstat -i
```

**Example output:**
```
Active Internet connections (only servers)
Proto Recv-Q Send-Q Local Address           Foreign Address         State      
tcp        0      0 127.0.0.1:631           0.0.0.0:*               LISTEN     
tcp        0      0 127.0.0.1:5432          0.0.0.0:*               LISTEN     
tcp6       0      0 ::1:631                 :::*                    LISTEN     
udp        0      0 0.0.0.0:5353            0.0.0.0:*                          
```

**Usage notes:**
- Legacy command, not installed by default on newer systems
- Install with: `sudo apt install net-tools`
- Use `ss` instead on modern systems
- Options: `-t` (TCP), `-u` (UDP), `-l` (listening), `-n` (numeric), `-p` (processes)
</div>

<div class="command-card">
<h4>ss - Socket statistics</h4>

```bash
# Display all listening TCP and UDP ports
ss -tuln

# Display all connections with process information
sudo ss -tulpn

# Display detailed socket information
ss -i

# Display summary statistics
ss -s
```

**Example output:**
```
Netid  State   Recv-Q  Send-Q   Local Address:Port    Peer Address:Port  Process                                                  
udp    UNCONN  0       0            0.0.0.0:5353         0.0.0.0:*                                                                
udp    UNCONN  0       0            0.0.0.0:323          0.0.0.0:*                                                                
tcp    LISTEN  0       4096       127.0.0.1:631          0.0.0.0:*                                                                
tcp    LISTEN  0       128        127.0.0.1:5432         0.0.0.0:*                                                                
```

**Usage notes:**
- Modern replacement for `netstat`
- Available on all current Linux distributions
- Faster and more feature-rich than `netstat`
- Same basic options as `netstat`: `-t` (TCP), `-u` (UDP), `-l` (listening), etc.
</div>

<div class="command-card">
<h4>nslookup - Query DNS records</h4>

```bash
# Basic DNS lookup
nslookup example.com

# Query specific DNS server
nslookup example.com 8.8.8.8

# Lookup specific record type
nslookup -type=MX example.com

# Reverse DNS lookup
nslookup 8.8.8.8
```

**Example output:**
```
Server:		127.0.0.53
Address:	127.0.0.53#53

Non-authoritative answer:
Name:	example.com
Address: 93.184.216.34
```

**Usage notes:**
- Available on most Linux distributions
- Simple tool for basic DNS queries
- Interactive mode available by running `nslookup` without arguments
- Being replaced by `dig` in many contexts
</div>

<div class="command-card">
<h4>dig - DNS lookup utility</h4>

```bash
# Basic DNS lookup
dig example.com

# Query specific DNS server
dig @8.8.8.8 example.com

# Lookup specific record type
dig example.com MX

# Reverse DNS lookup
dig -x 8.8.8.8

# Short answer format
dig example.com +short
```

**Example output:**
```
; <<>> DiG 9.18.18-0ubuntu0.24.04.1 <<>> example.com
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 39772
;; flags: qr rd ra; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 1

;; OPT PSEUDOSECTION:
; EDNS: version: 0, flags:; udp: 65494
;; QUESTION SECTION:
;example.com.			IN	A

;; ANSWER SECTION:
example.com.		86400	IN	A	93.184.216.34

;; Query time: 0 msec
;; SERVER: 127.0.0.53#53(127.0.0.53) (UDP)
;; WHEN: Fri Jun 21 15:20:45 CEST 2024
;; MSG SIZE  rcvd: 56
```

**Usage notes:**
- May not be installed by default, install with: `sudo apt install dnsutils`
- More powerful and flexible than `nslookup`
- Provides detailed information about DNS queries
- Preferred tool for DNS troubleshooting
</div>

<div class="command-card">
<h4>host - DNS lookup utility</h4>

```bash
# Basic DNS lookup
host example.com

# Lookup specific record type
host -t MX example.com

# Reverse DNS lookup
host 8.8.8.8

# Verbose output
host -v example.com
```

**Example output:**
```
example.com has address 93.184.216.34
example.com has IPv6 address 2606:2800:220:1:248:1893:25c8:1946
example.com mail is handled by 0 .
```

**Usage notes:**
- May not be installed by default, install with: `sudo apt install dnsutils`
- Simpler output format than `dig`
- Good middle ground between `nslookup` and `dig`
</div>

<div class="command-card">
<h4>hostname - Show or set system hostname</h4>

```bash
# Display hostname
hostname

# Display all IP addresses
hostname -I

# Display FQDN (Fully Qualified Domain Name)
hostname -f

# Display domain name
hostname -d
```

**Example output:**
```
workstation
```

**Usage notes:**
- Available on all Linux distributions
- `-I` option is particularly useful for getting all IP addresses
- To permanently change hostname, edit `/etc/hostname`
</div>

<div class="command-card">
<h4>ip neighbor - Manage ARP cache</h4>

```bash
# Show ARP cache (neighbor table)
ip neighbor show

# Add static ARP entry
sudo ip neighbor add 192.168.1.5 lladdr 00:11:22:33:44:55 dev eth0

# Delete ARP entry
sudo ip neighbor del 192.168.1.5 dev eth0
```

**Example output:**
```
192.168.1.1 dev enp0s31f6 lladdr 00:11:22:33:44:55 REACHABLE
192.168.1.5 dev enp0s31f6 lladdr 00:1a:2b:3c:4d:5e STALE
```

**Usage notes:**
- Modern replacement for `arp` command
- Available on all current Linux distributions
- Part of the `iproute2` package
</div>

<div class="command-card">
<h4>arp - Manipulate ARP cache (legacy command)</h4>

```bash
# Display ARP cache
arp -n

# Add static ARP entry
sudo arp -s 192.168.1.5 00:11:22:33:44:55

# Delete ARP entry
sudo arp -d 192.168.1.5
```

**Example output:**
```
Address                  HWtype  HWaddress           Flags Mask            Iface
192.168.1.1              ether   00:11:22:33:44:55   C                     enp0s31f6
192.168.1.5              ether   00:1a:2b:3c:4d:5e   C                     enp0s31f6
```

**Usage notes:**
- Legacy command, not installed by default on newer systems
- Install with: `sudo apt install net-tools`
- Use `ip neighbor` instead on modern systems
</div>
</details>

<details>
<summary><strong>Network Configuration</strong> (Click to expand)</summary>

<div class="command-card">
<h4>Network Configuration Files</h4>

**Ubuntu 18.04+ (Netplan):**
```bash
# Edit Netplan configuration
sudo nano /etc/netplan/01-netcfg.yaml

# Apply changes
sudo netplan apply
```

**Example configuration:**
```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    enp0s31f6:
      dhcp4: no
      addresses: [192.168.1.100/24]
      gateway4: 192.168.1.1
      nameservers:
        addresses: [8.8.8.8, 8.8.4.4]
```

**Older Ubuntu/Debian:**
```bash
# Edit interfaces file
sudo nano /etc/network/interfaces

# Restart networking
sudo systemctl restart networking
```

**Example configuration:**
```
auto eth0
iface eth0 inet static
    address 192.168.1.100
    netmask 255.255.255.0
    gateway 192.168.1.1
    dns-nameservers 8.8.8.8 8.8.4.4
```

**DNS Configuration:**
```bash
# Edit resolv.conf (may be overwritten by network manager)
sudo nano /etc/resolv.conf

# For persistent DNS on Ubuntu/Debian
sudo nano /etc/systemd/resolved.conf
```

**Usage notes:**
- Configuration methods vary by distribution and version
- Netplan is used on Ubuntu 18.04 and newer
- Traditional `/etc/network/interfaces` on older systems
- NetworkManager is often used on desktop systems
- systemd-networkd is often used on server systems
</div>

<div class="command-card">
<h4>Network Restart Commands</h4>

```bash
# Restart networking with systemd
sudo systemctl restart networking

# Restart NetworkManager
sudo systemctl restart NetworkManager

# Restart specific interface
sudo ip link set eth0 down
sudo ip link set eth0 up

# Restart all interfaces (older method)
sudo ifdown -a && sudo ifup -a
```

**Usage notes:**
- Method depends on your network configuration system
- For Netplan, use `sudo netplan apply`
- For NetworkManager, use `sudo systemctl restart NetworkManager`
- For systemd-networkd, use `sudo systemctl restart systemd-networkd`
- Interface-specific restarts are often safer than restarting all networking
</div>

<div class="command-card">
<h4>iwconfig - Configure wireless network interfaces (legacy command)</h4>

```bash
# Display wireless interfaces
iwconfig

# Set wireless interface essid (network name)
sudo iwconfig wlan0 essid "MyNetwork"

# Set wireless interface key (password)
sudo iwconfig wlan0 key s:password

# Set wireless interface mode
sudo iwconfig wlan0 mode Managed
```

**Example output:**
```
wlan0     IEEE 802.11  ESSID:"MyNetwork"  
          Mode:Managed  Frequency:2.412 GHz  Access Point: 00:11:22:33:44:55   
          Bit Rate=54 Mb/s   Tx-Power=15 dBm   
          Retry short limit:7   RTS thr:off   Fragment thr:off
          Power Management:on
          Link Quality=70/70  Signal level=-38 dBm  
          Rx invalid nwid:0  Rx invalid crypt:0  Rx invalid frag:0
          Tx excessive retries:0  Invalid misc:0   Missed beacon:0
```

**Usage notes:**
- Legacy command, not installed by default on newer systems
- Install with: `sudo apt install wireless-tools`
- Use `iw` or NetworkManager tools instead on modern systems
- Still useful for basic wireless diagnostics
</div>

<div class="command-card">
<h4>iw - Configure wireless devices</h4>

```bash
# List wireless devices
iw dev

# Scan for available networks
sudo iw dev wlan0 scan | grep SSID

# Connect to network (WPA/WPA2 requires wpa_supplicant)
sudo iw dev wlan0 connect "MyNetwork"

# Show link information
iw dev wlan0 link
```

**Example output:**
```
Interface wlan0
	ifindex 3
	wdev 0x1
	addr 00:11:22:33:44:55
	type managed
	channel 1 (2412 MHz), width: 20 MHz, center1: 2412 MHz
```

**Usage notes:**
- Modern replacement for `iwconfig`
- May not be installed by default, install with: `sudo apt install iw`
- Low-level tool, typically used with `wpa_supplicant`
- For most users, NetworkManager is easier to use
</div>
</details>

## Service Management (systemd)

```bash
# Start a service
sudo systemctl start service_name

# Stop a service
sudo systemctl stop service_name

# Restart a service
sudo systemctl restart service_name

# Enable a service to start at boot
sudo systemctl enable service_name

# Disable a service from starting at boot
sudo systemctl disable service_name

# Check service status
sudo systemctl status service_name

# List all services
systemctl list-units --type=service

# View service logs
sudo journalctl -u service_name

# View recent service logs
sudo journalctl -u service_name -n 50

# Follow service logs
sudo journalctl -u service_name -f
```

## User Management

```bash
# Add a new user
sudo adduser username

# Add a user to a group
sudo usermod -aG group username

# Change user password
sudo passwd username

# Delete a user
sudo deluser username

# Delete a user and their home directory
sudo deluser --remove-home username

# Switch to another user
su - username

# Run a command as another user
sudo -u username command

# List all users
cat /etc/passwd

# List all groups
cat /etc/group
```

## File Searching

```bash
# Find files by name
find /path/to/search -name "filename"

# Find files by type
find /path/to/search -type f  # files
find /path/to/search -type d  # directories

# Find files by size
find /path/to/search -size +10M  # larger than 10MB
find /path/to/search -size -10M  # smaller than 10MB

# Find files by modification time
find /path/to/search -mtime -7  # modified in the last 7 days

# Find and execute a command on each file
find /path/to/search -name "*.log" -exec rm {} \;

# Search for text in files
grep "search_text" filename
grep -r "search_text" /path/to/search  # recursive search
```

## Disk Management

```bash
# List block devices
lsblk

# Display disk usage
df -h

# Display directory space usage
du -sh /path/to/directory

# Check disk for errors
sudo fsck /dev/sdXY

# Mount a filesystem
sudo mount /dev/sdXY /mnt/mountpoint

# Unmount a filesystem
sudo umount /mnt/mountpoint

# Show mounted filesystems
mount

# Create a partition table
sudo fdisk /dev/sdX

# Format a partition
sudo mkfs.ext4 /dev/sdXY  # ext4 filesystem
sudo mkfs.xfs /dev/sdXY   # XFS filesystem

# Check SMART status of a disk
sudo smartctl -a /dev/sdX
```

## Proxmox-Specific Commands

```bash
# List virtual machines
qm list

# Start a virtual machine
qm start VM_ID

# Stop a virtual machine
qm stop VM_ID

# Shutdown a virtual machine (graceful)
qm shutdown VM_ID

# Reset a virtual machine
qm reset VM_ID

# Create a snapshot
qm snapshot VM_ID SNAPSHOT_NAME

# List snapshots
qm listsnapshot VM_ID

# Restore a snapshot
qm rollback VM_ID SNAPSHOT_NAME

# List containers
pct list

# Start a container
pct start CT_ID

# Stop a container
pct stop CT_ID

# Enter a container shell
pct enter CT_ID

# Show Proxmox cluster status
pvecm status

# Show storage information
pvesm status

# Show node status
pvenode status
```

## Log Files

```bash
# View system logs
less /var/log/syslog

# View authentication logs
less /var/log/auth.log

# View kernel logs
dmesg | less

# View boot logs
journalctl -b

# View service-specific logs
journalctl -u service_name

# View Apache access logs
less /var/log/apache2/access.log

# View Apache error logs
less /var/log/apache2/error.log

# View Nginx access logs
less /var/log/nginx/access.log

# View Nginx error logs
less /var/log/nginx/error.log
```

## Compression and Archiving

```bash
# Create a tar archive
tar -cvf archive.tar files_or_directories

# Create a compressed tar archive (gzip)
tar -czvf archive.tar.gz files_or_directories

# Create a compressed tar archive (bzip2)
tar -cjvf archive.tar.bz2 files_or_directories

# Extract a tar archive
tar -xvf archive.tar

# Extract a compressed tar archive (gzip or bzip2)
tar -xvf archive.tar.gz
tar -xvf archive.tar.bz2

# Zip files
zip -r archive.zip files_or_directories

# Unzip files
unzip archive.zip
```

## System Monitoring

```bash
# Display system resource usage
top

# Enhanced system monitor
htop

# Display I/O statistics
iostat

# Display CPU statistics
mpstat

# Display memory statistics
vmstat

# Display network statistics
netstat -s

# Continuous monitoring of system resources
sar

# Monitor file system events
inotifywait -m /path/to/monitor
```

## Firewall Management (UFW)

```bash
# Check firewall status
sudo ufw status

# Enable firewall
sudo ufw enable

# Disable firewall
sudo ufw disable

# Allow a port
sudo ufw allow 22/tcp

# Allow a service by name
sudo ufw allow ssh

# Deny a port
sudo ufw deny 3306/tcp

# Delete a rule
sudo ufw delete allow 22/tcp

# Allow from specific IP address
sudo ufw allow from 192.168.1.100

# Allow from IP to specific port
sudo ufw allow from 192.168.1.100 to any port 22
```

## Troubleshooting

```bash
# Check system resource usage
htop

# Check disk space
df -h

# Check memory usage
free -h

# Check for errors in system logs
grep -i error /var/log/syslog

# Check for failed services
systemctl --failed

# Check network connectivity
ping google.com

# Check DNS resolution
nslookup example.com

# Check open ports
sudo netstat -tulpn

# Check running processes
ps aux | grep process_name

# Check system load
uptime

# Check for zombie processes
ps aux | grep Z
```

## Server Room Management

<details>
<summary><strong>Proxmox Server Room Management</strong> (Click to expand)</summary>

<div class="command-card">
<h4>Proxmox Cluster Management</h4>

```bash
# Display cluster status
pvecm status

# List cluster nodes
pvecm nodes

# Add a node to the cluster
pvecm add IP_OF_CLUSTER_MASTER

# Remove a node from the cluster
pvecm delnode NODENAME

# Check cluster configuration
pvecm config
```

**Example output (pvecm status):**
```
Cluster information
------------------
Name:             proxmox-cluster
Config Version:   3
Transport:        knet
Secure auth:      on

Quorum information
------------------
Date:             Fri Jun 21 15:45:32 2024
Quorum provider:  corosync_votequorum
Nodes:            3
Node ID:          0x00000001
Ring ID:          1.345
Quorate:          Yes

Votequorum information
----------------------
Expected votes:   3
Highest expected: 3
Total votes:      3
Quorum:           2
Flags:            Quorate

Membership information
----------------------
    Nodeid      Votes Name
0x00000001          1 pve1 (local)
0x00000002          1 pve2
0x00000003          1 pve3
```

**Usage notes:**
- `pvecm` is the Proxmox Cluster Manager command
- Requires Proxmox VE installation
- Cluster setup requires at least 3 nodes for proper quorum
- Cluster communication uses a dedicated network interface
</div>

<div class="command-card">
<h4>Proxmox Virtual Machine Management</h4>

```bash
# List all virtual machines
qm list

# Start a virtual machine
qm start VM_ID

# Stop a virtual machine (hard stop)
qm stop VM_ID

# Shutdown a virtual machine (graceful)
qm shutdown VM_ID

# Reset a virtual machine
qm reset VM_ID

# Create a snapshot
qm snapshot VM_ID SNAPSHOT_NAME

# List snapshots
qm listsnapshot VM_ID

# Restore a snapshot
qm rollback VM_ID SNAPSHOT_NAME

# Clone a virtual machine
qm clone VM_ID NEW_VM_ID --name NEW_NAME

# Migrate a VM to another node
qm migrate VM_ID TARGET_NODE
```

**Example output (qm list):**
```
VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID       
101  web-server           running    2048       32           1234      
102  database-server      running    4096       64           5678      
103  backup-server        stopped    2048       32           -         
```

**Usage notes:**
- `qm` is the QEMU/KVM virtual machine manager command
- VM_ID is a unique identifier for each virtual machine
- Snapshots are point-in-time copies of VM state
- Live migration requires shared storage between nodes
</div>

<div class="command-card">
<h4>Proxmox Container Management</h4>

```bash
# List all containers
pct list

# Start a container
pct start CT_ID

# Stop a container
pct stop CT_ID

# Create a container from template
pct create CT_ID /var/lib/vz/template/cache/debian-11-standard_11.3-1_amd64.tar.zst \
  -hostname container1 \
  -net0 name=eth0,bridge=vmbr0,ip=dhcp \
  -storage local-lvm

# Enter a container shell
pct enter CT_ID

# Backup a container
vzdump CT_ID

# Restore a container backup
pzrestore /var/lib/vz/dump/vzdump-lxc-CT_ID.tar.gz NEW_CT_ID \
  --storage local-lvm
```

**Example output (pct list):**
```
VMID       Status     Lock         Name                
100        running                 container1          
101        stopped                 container2          
102        running                 container3          
```

**Usage notes:**
- `pct` is the Proxmox Container Toolkit command
- Containers are more lightweight than full VMs
- Container templates are available for various Linux distributions
- Containers share the host kernel but have isolated userspace
</div>

<div class="command-card">
<h4>Proxmox Storage Management</h4>

```bash
# List storage pools
pvesm status

# Show storage content
pvesm content STORAGE_ID

# Allocate disk image
pvesm alloc STORAGE_ID VM_ID disk-0 10G

# Import disk image
pvesm import STORAGE_ID ISO_FILE

# Create a new storage pool (ZFS)
pvesm add zfspool zfs-pool -pool rpool/data

# Create a new storage pool (LVM)
pvesm add lvmthin lvm-thin -thinpool data -vgname pve
```

**Example output (pvesm status):**
```
Name             Type     Status       Total       Used    Available       %
local             dir     active    458.64 GB  112.25 GB    346.39 GB  24.47%
local-lvm       lvmthin   active    344.62 GB   44.87 GB    299.75 GB  13.02%
local-zfs         zfs     active     1.36 TB   238.14 GB      1.13 TB  17.09%
```

**Usage notes:**
- `pvesm` is the Proxmox Storage Manager command
- Different storage types have different capabilities
- ZFS provides advanced features like snapshots and compression
- LVM thin provisioning allows overcommitting storage
</div>

<div class="command-card">
<h4>Proxmox Network Management</h4>

```bash
# Show network configuration
cat /etc/network/interfaces

# Create a bridge for VM networking
cat >> /etc/network/interfaces << EOF
auto vmbr1
iface vmbr1 inet static
    address 10.10.10.1/24
    bridge_ports none
    bridge_stp off
    bridge_fd 0
EOF

# Apply network changes
systemctl restart networking

# Show bridge information
brctl show

# Show bridge details
ip -d link show vmbr0
```

**Example configuration (/etc/network/interfaces):**
```
auto lo
iface lo inet loopback

auto enp0s31f6
iface enp0s31f6 inet manual

auto vmbr0
iface vmbr0 inet static
    address 192.168.1.100/24
    gateway 192.168.1.1
    bridge_ports enp0s31f6
    bridge_stp off
    bridge_fd 0
```

**Usage notes:**
- Proxmox uses Linux bridges for VM networking
- Each bridge acts as a virtual switch
- Physical interfaces are typically bridged for VM access
- Multiple bridges can be used for network isolation
</div>

<div class="command-card">
<h4>Proxmox Backup Management</h4>

```bash
# Create a backup of a VM
vzdump VM_ID --compress zstd --mode snapshot

# Create a backup of all VMs
vzdump --all --compress zstd --mode snapshot

# Schedule regular backups (edit /etc/cron.d/vzdump)
echo "0 2 * * * root vzdump --all --compress zstd --mode snapshot --quiet 1" > /etc/cron.d/vzdump

# Restore a backup
qmrestore /var/lib/vz/dump/vzdump-qemu-VM_ID.vma.zst NEW_VM_ID \
  --storage local-lvm
```

**Example output (vzdump):**
```
Starting backup of VM 101 (qemu)
Creating snapshot 'vzdump' on storage 'local-lvm'
Backing up VM 101 ...
Backup started at 2024-06-21 15:55:32
Status: running
Backup finished at 2024-06-21 15:56:45
Backup successful
```

**Usage notes:**
- `vzdump` is the Proxmox backup tool
- Supports both VMs and containers
- Can use snapshots for consistent backups
- Compression reduces backup size
- Backups stored in `/var/lib/vz/dump/` by default
</div>

<div class="command-card">
<h4>Proxmox System Monitoring</h4>

```bash
# Show system status
pvestatd status

# Show resource usage
pvesh get /nodes/$(hostname)/status

# Show running tasks
pvesh get /nodes/$(hostname)/tasks

# Show cluster resources
pvesh get /cluster/resources

# Monitor logs
tail -f /var/log/pve/tasks/index
```

**Example output (cluster resources):**
```
[
  {
    "cpu": 0.01,
    "disk": 238140,
    "diskwrite": 0,
    "id": "node/pve1",
    "level": "",
    "maxcpu": 8,
    "maxdisk": 1474560,
    "maxmem": 32768,
    "mem": 3840,
    "node": "pve1",
    "status": "online",
    "type": "node",
    "uptime": 1234567
  },
  {
    "cpu": 0.12,
    "disk": 32768,
    "diskwrite": 0,
    "id": "qemu/101",
    "name": "web-server",
    "node": "pve1",
    "status": "running",
    "type": "qemu",
    "uptime": 123456
  }
]
```

**Usage notes:**
- Proxmox provides various monitoring tools
- Web interface shows comprehensive statistics
- Command line tools provide detailed information
- Log files contain important system events
- Resource usage helps identify performance issues
</div>

<div class="command-card">
<h4>Proxmox High Availability</h4>

```bash
# Enable HA for a VM
ha-manager add vm:VM_ID --state started

# Disable HA for a VM
ha-manager remove vm:VM_ID

# Show HA status
ha-manager status

# Show HA resources
pvesh get /cluster/ha/resources

# Configure HA group
pvesh create /cluster/ha/groups -group ha_group1 -nodes "pve1,pve2,pve3"
```

**Example output (ha-manager status):**
```
quorum: OK
master: pve1 (1)
node pve1: active, resources: 2
node pve2: active, resources: 1
node pve3: active, resources: 1
service vm:101: started on pve1
service vm:102: started on pve2
service vm:103: started on pve3
```

**Usage notes:**
- High Availability requires at least 3 nodes
- Requires shared storage for VM disks
- Automatically restarts VMs on node failure
- Can define preferred nodes for specific VMs
- Requires proper network redundancy
</div>

<div class="command-card">
<h4>Proxmox Firewall Management</h4>

```bash
# Enable firewall
pve-firewall enable

# Show firewall status
pve-firewall status

# Show firewall rules
cat /etc/pve/firewall/cluster.fw

# Add a firewall rule (allow SSH)
echo "ACCEPT -p tcp -dport 22" >> /etc/pve/firewall/cluster.fw

# Apply firewall changes
pve-firewall restart
```

**Example configuration (/etc/pve/firewall/cluster.fw):**
```
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: ACCEPT

[RULES]
ACCEPT -p tcp -dport 22
ACCEPT -p tcp -dport 8006
ACCEPT -p tcp -dport 3128
```

**Usage notes:**
- Proxmox has a built-in firewall system
- Rules can be applied at cluster, node, or VM level
- Default policy should be restrictive (DROP)
- Always ensure SSH access is allowed
- Web interface provides a GUI for firewall management
</div>

<div class="command-card">
<h4>Proxmox Maintenance Tasks</h4>

```bash
# Update Proxmox packages
apt update && apt dist-upgrade

# Check for package updates
apt list --upgradable

# Clean package cache
apt clean

# Check disk health
smartctl -a /dev/sda

# Check ZFS pool status
zpool status

# Scrub ZFS pool
zpool scrub rpool

# Check system logs
journalctl -xef

# Check Proxmox logs
tail -f /var/log/pveproxy/access.log
```

**Example output (zpool status):**
```
  pool: rpool
 state: ONLINE
  scan: scrub repaired 0B in 01:23:45 with 0 errors on Sun Jun 16 03:45:12 2024
config:

	NAME        STATE     READ WRITE CKSUM
	rpool       ONLINE       0     0     0
	  mirror-0  ONLINE       0     0     0
	    sda2    ONLINE       0     0     0
	    sdb2    ONLINE       0     0     0

errors: No known data errors
```

**Usage notes:**
- Regular maintenance is essential for system health
- Keep Proxmox updated for security and features
- Monitor disk health to prevent data loss
- ZFS scrubs help detect and repair data corruption
- Log monitoring helps identify issues early
</div>
</details>

## Best Practices

<details>
<summary><strong>Linux System Administration Best Practices</strong> (Click to expand)</summary>

<div class="command-card">
<h4>Security Best Practices</h4>

1. **Use sudo with caution**: Be careful when using sudo, especially with commands like `rm -rf`.

2. **Use SSH keys instead of passwords**: SSH keys are more secure than passwords for remote access.
   ```bash
   # Generate SSH key
   ssh-keygen -t ed25519 -C "your_email@example.com"
   
   # Copy key to server
   ssh-copy-id user@server
   
   # Disable password authentication in /etc/ssh/sshd_config
   PasswordAuthentication no
   ```

3. **Keep the system updated**: Regularly update packages to ensure security patches are applied.
   ```bash
   # Ubuntu/Debian
   sudo apt update && sudo apt upgrade
   
   # Set up unattended upgrades for security patches
   sudo apt install unattended-upgrades
   sudo dpkg-reconfigure unattended-upgrades
   ```

4. **Use a firewall**: Configure and enable a firewall to restrict access.
   ```bash
   # Enable UFW with default rules
   sudo ufw default deny incoming
   sudo ufw default allow outgoing
   sudo ufw allow ssh
   sudo ufw enable
   ```

5. **Implement fail2ban**: Protect against brute force attacks.
   ```bash
   sudo apt install fail2ban
   sudo systemctl enable fail2ban
   sudo systemctl start fail2ban
   ```
</div>

<div class="command-card">
<h4>System Maintenance Best Practices</h4>

1. **Create backups before making changes**: Always back up important files before editing them.
   ```bash
   # Simple file backup
   cp /path/to/file /path/to/file.bak
   
   # System backup with rsync
   rsync -avz --delete /source/ /destination/
   ```

2. **Use version control for configuration files**: Track changes to important configuration files.
   ```bash
   # Initialize git repository for /etc
   cd /etc
   sudo git init
   sudo git add .
   sudo git commit -m "Initial commit"
   ```

3. **Monitor system resources regularly**: Keep an eye on disk space, memory usage, and CPU load.
   ```bash
   # Set up regular disk space checks
   echo "0 * * * * root df -h | grep -vE '^Filesystem|tmpfs|cdrom' | awk '{ print \$5 \" \" \$1 }' | while read output; do used=\$(echo \$output | awk '{ print \$1 }' | cut -d'%' -f1); if [ \$used -ge 90 ]; then echo \"Disk space critical on \$(hostname) - \$output\" | mail -s \"Disk Space Alert\" admin@example.com; fi; done" > /etc/cron.d/disk_check
   ```

4. **Implement log rotation**: Prevent logs from filling up disk space.
   ```bash
   # Configure logrotate for application logs
   cat > /etc/logrotate.d/myapp << EOF
   /var/log/myapp/*.log {
       weekly
       rotate 4
       compress
       delaycompress
       missingok
       notifempty
       create 0640 www-data www-data
   }
   EOF
   ```

5. **Document your changes**: Keep a record of system changes for future reference.
   ```bash
   # Create a change log
   sudo mkdir -p /var/log/changes
   sudo touch /var/log/changes/system_changes.log
   sudo echo "$(date) - Updated network configuration" >> /var/log/changes/system_changes.log
   ```
</div>

<div class="command-card">
<h4>Performance Best Practices</h4>

1. **Use screen or tmux for long-running processes**: These tools allow you to detach from a session and reconnect later.
   ```bash
   # Start a new screen session
   screen -S session_name
   
   # Detach from screen: Ctrl+A, D
   # Reattach to screen
   screen -r session_name
   ```

2. **Schedule resource-intensive tasks during off-hours**: Use cron to schedule tasks.
   ```bash
   # Run backup at 2 AM
   echo "0 2 * * * root /usr/local/bin/backup.sh" > /etc/cron.d/backup
   ```

3. **Use appropriate filesystem for the workload**: Different filesystems have different strengths.
   - **ext4**: Good general-purpose filesystem
   - **XFS**: Good for large files and high-performance workloads
   - **ZFS**: Advanced features like snapshots, compression, and data integrity
   - **Btrfs**: Similar to ZFS with built-in RAID and snapshot capabilities

4. **Optimize disk I/O**: Configure disk schedulers appropriately.
   ```bash
   # Check current scheduler
   cat /sys/block/sda/queue/scheduler
   
   # Set scheduler (temporary)
   echo mq-deadline > /sys/block/sda/queue/scheduler
   
   # Set scheduler permanently in /etc/default/grub
   GRUB_CMDLINE_LINUX="... elevator=mq-deadline"
   ```

5. **Use appropriate swappiness**: Adjust how aggressively the system swaps memory.
   ```bash
   # Check current swappiness
   cat /proc/sys/vm/swappiness
   
   # Set swappiness temporarily
   sudo sysctl vm.swappiness=10
   
   # Set swappiness permanently in /etc/sysctl.conf
   vm.swappiness=10
   ```
</div>

<div class="command-card">
<h4>Testing and Deployment Best Practices</h4>

1. **Test commands in a non-production environment first**: Whenever possible, test commands in a test environment before running them on production systems.

2. **Use configuration management tools**: Tools like Ansible, Puppet, or Chef help maintain consistent configurations.
   ```bash
   # Example Ansible playbook execution
   ansible-playbook -i inventory.ini playbook.yml
   ```

3. **Implement continuous integration/deployment**: Automate testing and deployment processes.
   ```bash
   # Example CI/CD pipeline script
   #!/bin/bash
   set -e
   
   # Run tests
   ./run_tests.sh
   
   # If tests pass, deploy
   if [ $? -eq 0 ]; then
       ./deploy.sh
   fi
   ```

4. **Use containers for application isolation**: Docker or LXC containers provide isolation and portability.
   ```bash
   # Run application in Docker container
   docker run -d --name myapp -p 8080:80 myapp:latest
   ```

5. **Implement blue-green deployments**: Minimize downtime during updates.
   ```bash
   # Switch traffic from blue to green environment
   sudo ln -sf /etc/nginx/sites-available/green.conf /etc/nginx/sites-enabled/app.conf
   sudo systemctl reload nginx
   ```
</div>

<div class="command-card">
<h4>Proxmox-Specific Best Practices</h4>

1. **Use a dedicated storage network**: Separate VM traffic from storage traffic.
   ```bash
   # Example network configuration with separate storage network
   auto enp1s0
   iface enp1s0 inet manual
   
   auto enp2s0
   iface enp2s0 inet manual
   
   auto vmbr0
   iface vmbr0 inet static
       address 192.168.1.100/24
       gateway 192.168.1.1
       bridge_ports enp1s0
       bridge_stp off
       bridge_fd 0
   
   auto vmbr1
   iface vmbr1 inet static
       address 10.10.10.100/24
       bridge_ports enp2s0
       bridge_stp off
       bridge_fd 0
   ```

2. **Implement proper backup strategy**: Regular backups with retention policy.
   ```bash
   # Create backup configuration
   cat > /etc/vzdump.conf << EOF
   tmpdir: /mnt/backup/tmp
   storage: backup
   mode: snapshot
   compress: zstd
   maxfiles: 5
   EOF
   
   # Schedule daily backups at 2 AM
   echo "0 2 * * * root vzdump --all --quiet 1" > /etc/cron.d/vzdump
   ```

3. **Use resource limits for VMs and containers**: Prevent resource contention.
   ```bash
   # Set CPU and memory limits for a VM
   qm set 101 --memory 4096 --cores 2 --cpulimit 0.5
   
   # Set limits for a container
   pct set 100 --memory 2048 --cpulimit 0.25
   ```

4. **Implement high availability for critical VMs**: Ensure service continuity.
   ```bash
   # Enable HA for critical VM
   ha-manager add vm:101 --state started
   ```

5. **Monitor Proxmox health regularly**: Check for issues proactively.
   ```bash
   # Create monitoring script
   cat > /usr/local/bin/check_proxmox.sh << 'EOF'
   #!/bin/bash
   
   # Check node status
   node_status=$(pvesh get /nodes/$(hostname)/status)
   
   # Check storage status
   storage_status=$(pvesm status)
   
   # Check cluster status
   cluster_status=$(pvecm status)
   
   # Output results
   echo "Node Status:"
   echo "$node_status"
   echo
   echo "Storage Status:"
   echo "$storage_status"
   echo
   echo "Cluster Status:"
   echo "$cluster_status"
   EOF
   
   chmod +x /usr/local/bin/check_proxmox.sh
   
   # Schedule daily health check
   echo "0 7 * * * root /usr/local/bin/check_proxmox.sh | mail -s 'Proxmox Health Check' admin@example.com" > /etc/cron.d/proxmox_health
   ```
</div>
</details>

## Additional Resources

- [Ubuntu Documentation](https://help.ubuntu.com/)
- [Debian Documentation](https://www.debian.org/doc/)
- [Proxmox Documentation](https://pve.proxmox.com/wiki/Main_Page)
- [Linux Command Library](https://linuxcommandlibrary.com/)
- [Man Pages](https://linux.die.net/man/)