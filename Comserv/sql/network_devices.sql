-- Network Devices Table
CREATE TABLE IF NOT EXISTS network_devices (
    id INT AUTO_INCREMENT PRIMARY KEY,
    device_name VARCHAR(255) NOT NULL,
    ip_address VARCHAR(45) NOT NULL,
    mac_address VARCHAR(45),
    device_type VARCHAR(100),
    location VARCHAR(255),
    purpose VARCHAR(255),
    notes TEXT,
    site_name VARCHAR(100) NOT NULL,
    created_at DATETIME,
    updated_at DATETIME
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Add some initial sample data
INSERT INTO network_devices (device_name, ip_address, mac_address, device_type, location, purpose, notes, site_name, created_at)
VALUES 
('Main Router', '192.168.1.1', '00:11:22:33:44:55', 'Router', 'Server Room', 'Main internet gateway', 'Cisco router providing internet access and firewall', 'CSC', NOW()),
('Core Switch', '192.168.1.2', '00:11:22:33:44:56', 'Switch', 'Server Room', 'Core network switch', 'Cisco Catalyst 9300 Series', 'CSC', NOW()),
('Office AP', '192.168.1.3', '00:11:22:33:44:57', 'Access Point', 'Main Office', 'Wireless access', 'Cisco Meraki MR Series', 'CSC', NOW()),
('MCOOP Router', '10.0.0.1', '00:11:22:33:44:58', 'Router', 'MCOOP Office', 'Main router for MCOOP', 'Ubiquiti EdgeRouter', 'MCOOP', NOW()),
('MCOOP Switch', '10.0.0.2', '00:11:22:33:44:59', 'Switch', 'MCOOP Office', 'Network switch for MCOOP', 'Ubiquiti EdgeSwitch', 'MCOOP', NOW()),
('BMaster Server', '172.16.0.10', '00:11:22:33:44:60', 'Server', 'BMaster Office', 'Main server for BMaster', 'Dell PowerEdge R740', 'BMaster', NOW());