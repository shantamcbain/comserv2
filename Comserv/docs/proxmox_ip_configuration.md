# Proxmox IP Address Configuration Guide

This document provides detailed instructions for configuring IP addresses in Proxmox VE environments, covering both the host system and guest virtual machines/containers.

## Table of Contents

1. [Host System IP Configuration](#host-system-ip-configuration)
2. [Container (LXC) IP Configuration](#container-lxc-ip-configuration)
3. [Virtual Machine (QEMU/KVM) IP Configuration](#virtual-machine-qemukvm-ip-configuration)
4. [Network Troubleshooting](#network-troubleshooting)
5. [Advanced Network Configurations](#advanced-network-configurations)

## Host System IP Configuration

### Viewing Current Network Configuration

```bash
# View all network interfaces
ip addr show

# View specific interface
ip addr show vmbr0

# View routing table
ip route show

# View DNS configuration
cat /etc/resolv.conf
```

### Modifying Host IP Address

The primary method to configure network interfaces in Proxmox VE is by editing the `/etc/network/interfaces` file:

```bash
# Edit network configuration file
nano /etc/network/interfaces
```

#### Example Static IP Configuration

```
auto lo
iface lo inet loopback

auto eno1
iface eno1 inet manual

auto vmbr0
iface vmbr0 inet static
    address 192.168.1.100/24
    gateway 192.168.1.1
    bridge-ports eno1
    bridge-stp off
    bridge-fd 0
```

#### Example DHCP Configuration

```
auto lo
iface lo inet loopback

auto eno1
iface eno1 inet manual

auto vmbr0
iface vmbr0 inet dhcp
    bridge-ports eno1
    bridge-stp off
    bridge-fd 0
```

### Applying Network Changes

After modifying the network configuration, you need to apply the changes:

```bash
# Apply changes without reboot (recommended)
ifreload -a

# Alternative: restart networking service
systemctl restart networking

# Check if changes were applied
ip addr show
```

### Updating Hostname and Hosts File

When changing IP addresses, you should also update the hostname and hosts file:

```bash
# Set hostname
hostnamectl set-hostname proxmox-node1

# Edit hosts file
nano /etc/hosts
```

Example `/etc/hosts` file:
```
127.0.0.1 localhost
192.168.1.100 proxmox-node1.example.com proxmox-node1

# The following lines are desirable for IPv6 capable hosts
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
```

## Container (LXC) IP Configuration

### Setting IP Address During Container Creation

You can set the IP address when creating a new container:

```bash
# Create container with DHCP
pct create 100 local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst \
  --hostname container1 \
  --memory 512 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp

# Create container with static IP
pct create 101 local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst \
  --hostname container2 \
  --memory 512 \
  --net0 name=eth0,bridge=vmbr0,ip=192.168.1.101/24,gw=192.168.1.1
```

### Changing Container IP Address After Creation

You can modify the IP address of an existing container:

```bash
# Change to DHCP
pct set 100 --net0 name=eth0,bridge=vmbr0,ip=dhcp

# Change to static IP
pct set 101 --net0 name=eth0,bridge=vmbr0,ip=192.168.1.102/24,gw=192.168.1.1

# Apply changes by restarting the container
pct restart 101
```

### Adding Multiple Network Interfaces

Containers can have multiple network interfaces:

```bash
# Add a second network interface
pct set 101 --net1 name=eth1,bridge=vmbr1,ip=10.10.10.101/24

# Add a third network interface without IP (to be configured inside the container)
pct set 101 --net2 name=eth2,bridge=vmbr0,ip=manual
```

### Configuring IP Inside the Container

For manual IP configuration, you need to configure the network inside the container:

```bash
# Enter the container
pct enter 101

# For Ubuntu/Debian containers
nano /etc/netplan/01-netcfg.yaml

# Example netplan configuration
network:
  version: 2
  ethernets:
    eth0:
      addresses: [192.168.1.101/24]
      gateway4: 192.168.1.1
      nameservers:
        addresses: [8.8.8.8, 8.8.4.4]
    eth2:
      addresses: [192.168.2.101/24]

# Apply netplan configuration
netplan apply

# For CentOS/RHEL containers
nano /etc/sysconfig/network-scripts/ifcfg-eth0

# Example ifcfg configuration
DEVICE=eth0
BOOTPROTO=static
IPADDR=192.168.1.101
NETMASK=255.255.255.0
GATEWAY=192.168.1.1
ONBOOT=yes

# Restart networking
systemctl restart network
```

## Virtual Machine (QEMU/KVM) IP Configuration

### Setting IP Address for VMs

For QEMU/KVM virtual machines, there are two approaches to IP configuration:

1. **Guest OS Configuration**: Configure the IP address within the guest operating system
2. **QEMU Guest Agent**: Use the QEMU guest agent to set the IP address from the host

#### Using QEMU Guest Agent

First, ensure the QEMU guest agent is installed and enabled in the VM:

```bash
# Enable QEMU guest agent in VM configuration
qm set 100 --agent enabled=1

# Inside the VM (for Debian/Ubuntu)
apt update
apt install qemu-guest-agent
systemctl enable qemu-guest-agent
systemctl start qemu-guest-agent

# Inside the VM (for CentOS/RHEL)
dnf install qemu-guest-agent
systemctl enable qemu-guest-agent
systemctl start qemu-guest-agent
```

Then, you can set the IP address using the `--ipconfig` option:

```bash
# Set static IP for the first network interface
qm set 100 --ipconfig0 ip=192.168.1.100/24,gw=192.168.1.1

# Set static IP for the second network interface
qm set 100 --ipconfig1 ip=10.10.10.100/24

# Set DHCP for the first network interface
qm set 100 --ipconfig0 ip=dhcp
```

### Viewing VM IP Addresses

If the QEMU guest agent is running, you can view the VM's IP addresses:

```bash
# Get VM agent information
qm agent 100 info

# Get VM network interfaces
qm agent 100 network-get-interfaces
```

### Cloud-Init Configuration

For VMs created from Cloud-Init templates, you can set the IP address using Cloud-Init:

```bash
# Set Cloud-Init IP configuration
qm set 100 --ipconfig0 ip=192.168.1.100/24,gw=192.168.1.1

# Set Cloud-Init DNS servers
qm set 100 --nameserver 8.8.8.8

# Set Cloud-Init search domain
qm set 100 --searchdomain example.com
```

## Network Troubleshooting

### Checking Connectivity

```bash
# Check if an IP address is reachable
ping 192.168.1.100

# Trace the route to an IP address
traceroute 192.168.1.100

# Check DNS resolution
nslookup example.com

# Check open ports
netstat -tuln
```

### Debugging Network Issues

```bash
# Check bridge status
brctl show

# Check firewall status
pve-firewall status

# View firewall rules
iptables -L

# Check network interface statistics
ip -s link show

# Monitor network traffic
tcpdump -i vmbr0
```

### Common Network Issues and Solutions

1. **VM/Container Cannot Access Internet**:
   - Check gateway configuration
   - Verify DNS settings
   - Check firewall rules
   - Ensure IP forwarding is enabled: `sysctl net.ipv4.ip_forward`

2. **Cannot Connect to VM/Container**:
   - Verify IP address configuration
   - Check firewall rules
   - Ensure bridge interface is up
   - Verify network interface is attached to the correct bridge

3. **DHCP Not Working**:
   - Check DHCP server configuration
   - Verify network interface is set to use DHCP
   - Check DHCP client logs

## Advanced Network Configurations

### VLAN Configuration

```bash
# Create a VLAN interface on the host
echo "auto vmbr0.10
iface vmbr0.10 inet static
    address 10.10.10.1/24
    vlan-raw-device vmbr0" >> /etc/network/interfaces

# Apply changes
ifreload -a

# Create a container with VLAN tag
pct create 102 local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst \
  --hostname container-vlan \
  --memory 512 \
  --net0 name=eth0,bridge=vmbr0,tag=10,ip=10.10.10.2/24,gw=10.10.10.1

# Create a VM with VLAN tag
qm create 102 --memory 1024 --net0 virtio,bridge=vmbr0,tag=10
```

### Bond Configuration

```bash
# Create a bond interface
echo "auto bond0
iface bond0 inet manual
    bond-slaves eno1 eno2
    bond-miimon 100
    bond-mode 802.3ad
    bond-xmit-hash-policy layer2+3

auto vmbr0
iface vmbr0 inet static
    address 192.168.1.100/24
    gateway 192.168.1.1
    bridge-ports bond0
    bridge-stp off
    bridge-fd 0" >> /etc/network/interfaces

# Apply changes
ifreload -a
```

### IPv6 Configuration

```bash
# Configure IPv6 on the host
echo "auto vmbr0
iface vmbr0 inet static
    address 192.168.1.100/24
    gateway 192.168.1.1
    bridge-ports eno1
    bridge-stp off
    bridge-fd 0

iface vmbr0 inet6 static
    address 2001:db8::100/64
    gateway 2001:db8::1" >> /etc/network/interfaces

# Create a container with IPv6
pct create 103 local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst \
  --hostname container-ipv6 \
  --memory 512 \
  --net0 name=eth0,bridge=vmbr0,ip=192.168.1.103/24,gw=192.168.1.1,ip6=2001:db8::103/64,gw6=2001:db8::1
```

### NAT Configuration

```bash
# Create a NAT network
echo "auto vmbr1
iface vmbr1 inet static
    address 10.10.10.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up echo 1 > /proc/sys/net/ipv4/ip_forward
    post-up iptables -t nat -A POSTROUTING -s '10.10.10.0/24' -o vmbr0 -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s '10.10.10.0/24' -o vmbr0 -j MASQUERADE" >> /etc/network/interfaces

# Apply changes
ifreload -a

# Create a container on the NAT network
pct create 104 local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst \
  --hostname container-nat \
  --memory 512 \
  --net0 name=eth0,bridge=vmbr1,ip=10.10.10.2/24,gw=10.10.10.1
```

## Additional Resources

- [Proxmox VE Network Configuration Wiki](https://pve.proxmox.com/wiki/Network_Configuration)
- [Proxmox VE Container Documentation](https://pve.proxmox.com/wiki/Linux_Container)
- [Proxmox VE QEMU/KVM Documentation](https://pve.proxmox.com/wiki/Qemu/KVM_Virtual_Machines)
- [Proxmox VE Firewall Documentation](https://pve.proxmox.com/wiki/Firewall)
- [Proxmox VE Cloud-Init Support](https://pve.proxmox.com/wiki/Cloud-Init_Support)