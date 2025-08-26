-- SQL for mail_domains table
-- This table stores mail configuration for domains, linked to the sitedomain table

CREATE TABLE mail_domains (
  id INT AUTO_INCREMENT PRIMARY KEY,
  domain_id INT NOT NULL,
  dkim_selector VARCHAR(255) NOT NULL DEFAULT 'mail',
  dkim_public_key TEXT,
  spf_record TEXT,
  mx_records JSON,
  dmarc_record TEXT,
  status ENUM('pending', 'active', 'error') NOT NULL DEFAULT 'pending',
  error_message TEXT,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  FOREIGN KEY (domain_id) REFERENCES sitedomain(id) ON DELETE CASCADE
);

-- Add index for faster lookups
CREATE INDEX idx_mail_domains_domain_id ON mail_domains(domain_id);

-- Add comment to table
ALTER TABLE mail_domains COMMENT 'Stores mail configuration for domains managed by the system';