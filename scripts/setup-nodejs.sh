#!/bin/bash
# Quick-start Node.js setup script for Comserv Zencoder Agents
# Automates setup for both local development and Docker environments

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Header
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Comserv Node.js Environment Setup${NC}"
echo -e "${GREEN}========================================${NC}\n"

# Configuration
NODE_VERSION="20"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Function: Print status
print_status() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

# Function: Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Step 1: Check system requirements
echo -e "${YELLOW}Step 1: Checking System Requirements${NC}"
echo ""

if command_exists node; then
    NODE_INSTALLED=$(node --version)
    print_status "Node.js already installed: $NODE_INSTALLED"
else
    print_warning "Node.js not found. Installing..."
    
    if command_exists apt-get; then
        sudo apt-get update
        curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | sudo -E bash -
        sudo apt-get install -y nodejs
        print_status "Node.js installed"
    else
        print_error "apt-get not found. Please install Node.js manually."
        exit 1
    fi
fi

if command_exists npm; then
    NPM_VERSION=$(npm --version)
    print_status "npm installed: v$NPM_VERSION"
else
    print_error "npm not found"
    exit 1
fi

echo ""

# Step 2: Project setup
echo -e "${YELLOW}Step 2: Project Configuration${NC}"
echo ""

cd "$PROJECT_ROOT"

if [ ! -f "package.json" ]; then
    print_warning "package.json not found. Creating..."
    npm init -y > /dev/null
    print_status "package.json created"
else
    print_status "package.json found"
fi

# Install dependencies
print_status "Installing Node.js dependencies..."
npm install --legacy-peer-deps
print_status "Dependencies installed"

echo ""

# Step 3: Verify installation
echo -e "${YELLOW}Step 3: Verification${NC}"
echo ""

print_status "Node.js version: $(node --version)"
print_status "npm version: $(npm --version)"
print_status "Project root: $PROJECT_ROOT"

# List installed packages
echo ""
print_status "Installed packages:"
npm list --depth=0 2>/dev/null | grep -v "npm WARN" || true

echo ""

# Step 4: Docker setup (optional)
echo -e "${YELLOW}Step 4: Docker Environment (Optional)${NC}"
echo ""

if command_exists docker; then
    print_status "Docker found"
    
    read -p "Do you want to rebuild Docker images? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_warning "Building Docker images (this may take a few minutes)..."
        docker compose build
        print_status "Docker images built successfully"
    fi
else
    print_warning "Docker not found. Skipping Docker setup."
fi

echo ""

# Step 5: PyCharm configuration hints
echo -e "${YELLOW}Step 5: PyCharm Configuration${NC}"
echo ""
echo "Manual steps required in PyCharm:"
echo "1. Go to File > Settings > Languages & Frameworks > Node.js and NPM"
echo "2. Set Node interpreter to: $(which node)"
echo "3. Set npm package manager to: $(which npm)"
echo "4. Click OK and restart PyCharm"

echo ""

# Step 6: Test agent environment
echo -e "${YELLOW}Step 6: Agent Environment Test${NC}"
echo ""

if [ -d ".qodo" ]; then
    AGENT_COUNT=$(find .qodo/agents -type f 2>/dev/null | wc -l)
    print_status "Agent directory found with $AGENT_COUNT agent files"
else
    print_warning ".qodo/agents directory not found. Create agent files there."
fi

if [ -f "agents/index.js" ]; then
    print_status "Agent index file found"
else
    print_warning "agents/index.js not found. Agent environment not fully configured."
fi

echo ""

# Summary
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Setup Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Next steps:"
echo "1. Close and reopen PyCharm to reload Node.js configuration"
echo "2. Test in PyCharm Terminal: node --version && npm --version"
echo "3. Review NODEJS_SETUP_GUIDE.md for detailed configuration"
echo ""

# Cleanup
print_status "Setup script completed successfully"