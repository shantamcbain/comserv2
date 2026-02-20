#!/bin/bash

# Setup Web-Based SSH Terminal on Port 3001
# This script installs and configures wetty for interactive SSH access

echo "========================================="
echo "SSH Terminal Setup for Docker Management"
echo "========================================="
echo ""

# Check if running on workstation.local
HOSTNAME=$(hostname)
echo "Current hostname: $HOSTNAME"
echo ""

# Check if wetty is already installed
if command -v wetty &> /dev/null; then
    echo "✓ wetty is already installed"
    WETTY_VERSION=$(wetty --version 2>&1 | head -1)
    echo "  Version: $WETTY_VERSION"
else
    echo "Installing wetty..."
    
    # Check for npm
    if ! command -v npm &> /dev/null; then
        echo "✗ npm not found. Installing Node.js and npm..."
        curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
        sudo apt-get install -y nodejs
    fi
    
    # Install wetty globally
    echo "Installing wetty globally..."
    sudo npm install -g wetty
    
    if [ $? -eq 0 ]; then
        echo "✓ wetty installed successfully"
    else
        echo "✗ Failed to install wetty"
        exit 1
    fi
fi

echo ""
echo "========================================="
echo "Creating systemd service for wetty"
echo "========================================="
echo ""

# Create systemd service file
sudo tee /etc/systemd/system/wetty-ssh.service > /dev/null <<'EOF'
[Unit]
Description=Wetty SSH Terminal on Port 3001
After=network.target

[Service]
Type=simple
User=shanta
WorkingDirectory=/home/shanta
ExecStart=/usr/bin/wetty --port 3001 --host 0.0.0.0 --ssh-host 192.168.1.126 --ssh-user ubuntu --title "Production SSH Terminal"
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

if [ $? -eq 0 ]; then
    echo "✓ Systemd service file created: /etc/systemd/system/wetty-ssh.service"
else
    echo "✗ Failed to create systemd service file"
    exit 1
fi

echo ""
echo "========================================="
echo "Starting wetty service"
echo "========================================="
echo ""

# Reload systemd, enable and start the service
sudo systemctl daemon-reload
sudo systemctl enable wetty-ssh.service
sudo systemctl start wetty-ssh.service

# Check service status
sleep 2
if systemctl is-active --quiet wetty-ssh.service; then
    echo "✓ wetty service is running"
    echo ""
    sudo systemctl status wetty-ssh.service --no-pager | head -10
else
    echo "✗ wetty service failed to start"
    echo ""
    sudo journalctl -u wetty-ssh.service -n 20 --no-pager
    exit 1
fi

echo ""
echo "========================================="
echo "Setup Complete!"
echo "========================================="
echo ""
echo "✓ Web-based SSH terminal is now running on port 3001"
echo ""
echo "Access URLs:"
echo "  - http://workstation.local:3001/"
echo "  - http://localhost:3001/"
echo "  - http://192.168.1.198:3001/ (if accessible from network)"
echo ""
echo "Default SSH target: ubuntu@192.168.1.126"
echo ""
echo "Service Management Commands:"
echo "  - Start:   sudo systemctl start wetty-ssh"
echo "  - Stop:    sudo systemctl stop wetty-ssh"
echo "  - Restart: sudo systemctl restart wetty-ssh"
echo "  - Status:  sudo systemctl status wetty-ssh"
echo "  - Logs:    sudo journalctl -u wetty-ssh -f"
echo ""
echo "Test it now:"
echo "  1. Open: http://workstation.local:3000/admin/docker-containers"
echo "  2. Expand: SSH Terminal (Port 3001) section"
echo "  3. Click: Open SSH Terminal (New Window)"
echo "  4. Enter password when prompted"
echo ""
