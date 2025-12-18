-- AI Chat Documentation Feature - Phase 1: Database Schema
-- Created: 2025-12-16
-- Purpose: Create tables for AI chat with documentation search, code search, web search results, and model configuration

-- Extend ai_messages table with new columns for AI chat feature
ALTER TABLE ai_messages ADD COLUMN IF NOT EXISTS user_id INT NULL AFTER conversation_id,
    ADD COLUMN IF NOT EXISTS agent_type ENUM('documentation', 'helpdesk', 'ency', 'beekeeping', 'hamradio') DEFAULT 'documentation' NULL AFTER metadata,
    ADD COLUMN IF NOT EXISTS model_used VARCHAR(100) NULL AFTER agent_type,
    ADD COLUMN IF NOT EXISTS search_context JSON NULL AFTER model_used,
    ADD COLUMN IF NOT EXISTS sources_cited JSON NULL AFTER search_context,
    ADD COLUMN IF NOT EXISTS user_role VARCHAR(100) NULL AFTER sources_cited,
    ADD COLUMN IF NOT EXISTS response_time_ms INT NULL AFTER user_role,
    ADD COLUMN IF NOT EXISTS tokens_used INT NULL AFTER response_time_ms,
    ADD COLUMN IF NOT EXISTS is_verified BOOLEAN DEFAULT 0 NOT NULL AFTER tokens_used,
    ADD COLUMN IF NOT EXISTS ip_address VARCHAR(45) NULL AFTER is_verified,
    ADD INDEX idx_agent_type (agent_type),
    ADD INDEX idx_model_used (model_used),
    ADD INDEX idx_user_role (user_role),
    ADD INDEX idx_user_id (user_id),
    ADD INDEX idx_is_verified (is_verified);

-- Create documentation_metadata_index table for full-text search of .tt files
CREATE TABLE IF NOT EXISTS documentation_metadata_index (
    id INT AUTO_INCREMENT PRIMARY KEY,
    file_path VARCHAR(512) NOT NULL UNIQUE,
    file_type ENUM('tt', 'md') NOT NULL,
    title VARCHAR(512) NOT NULL,
    excerpt TEXT,
    searchable_text LONGTEXT NOT NULL,
    content_hash VARCHAR(64) NOT NULL,
    role_access JSON,
    indexed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_file_modified TIMESTAMP NULL,
    file_size INT,
    
    FULLTEXT INDEX ft_searchable_text (searchable_text),
    INDEX idx_content_hash (content_hash),
    INDEX idx_file_type (file_type),
    INDEX idx_indexed_at (indexed_at),
    
    UNIQUE KEY uk_file_path (file_path)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
COMMENT='Metadata index for documentation files with full-text search support';

-- Create code_search_index table for developer/admin code searches
CREATE TABLE IF NOT EXISTS code_search_index (
    id INT AUTO_INCREMENT PRIMARY KEY,
    file_path VARCHAR(512) NOT NULL UNIQUE,
    file_type ENUM('pm', 'tt', 'sql') NOT NULL,
    code_elements JSON,
    searchable_code LONGTEXT NOT NULL,
    content_hash VARCHAR(64) NOT NULL,
    indexed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    min_role ENUM('developer', 'admin') NOT NULL,
    file_size INT,
    
    FULLTEXT INDEX ft_searchable_code (searchable_code),
    INDEX idx_content_hash (content_hash),
    INDEX idx_file_type (file_type),
    INDEX idx_min_role (min_role),
    INDEX idx_indexed_at (indexed_at),
    
    UNIQUE KEY uk_file_path (file_path)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
COMMENT='Code index for developers and admins to search .pm and .tt code';

-- Create web_search_results table for pending web search approvals
CREATE TABLE IF NOT EXISTS web_search_results (
    id INT AUTO_INCREMENT PRIMARY KEY,
    query VARCHAR(500) NOT NULL,
    result_title VARCHAR(512) NOT NULL,
    result_url VARCHAR(1000) NOT NULL,
    result_snippet LONGTEXT NOT NULL,
    full_content LONGTEXT,
    source_type ENUM('web', 'public_domain_book', 'arxiv', 'github', 'stackoverflow') DEFAULT 'web' NOT NULL,
    found_by_user_id INT NOT NULL,
    is_verified BOOLEAN DEFAULT 0 NOT NULL,
    verified_by_user_id INT NULL,
    verification_notes TEXT,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    verified_at TIMESTAMP NULL,
    used_in_ai_message_id INT NULL,
    
    INDEX idx_query (query),
    INDEX idx_is_verified (is_verified),
    INDEX idx_created_at (created_at),
    INDEX idx_found_by_user_id (found_by_user_id),
    INDEX idx_verified_by_user_id (verified_by_user_id),
    INDEX idx_used_in_ai_message_id (used_in_ai_message_id),
    
    FOREIGN KEY (found_by_user_id) REFERENCES users(id) ON DELETE CASCADE,
    FOREIGN KEY (verified_by_user_id) REFERENCES users(id) ON DELETE SET NULL,
    FOREIGN KEY (used_in_ai_message_id) REFERENCES ai_messages(id) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
COMMENT='Web search results pending admin verification before adding to documentation index';

-- Create ai_model_config table for admin model configuration
CREATE TABLE IF NOT EXISTS ai_model_config (
    id INT AUTO_INCREMENT PRIMARY KEY,
    role VARCHAR(100) NOT NULL,
    agent_type VARCHAR(100) NOT NULL,
    model_name VARCHAR(100) NOT NULL,
    enabled BOOLEAN DEFAULT 1 NOT NULL,
    api_endpoint VARCHAR(500) NOT NULL,
    api_key_encrypted VARCHAR(512),
    temperature FLOAT,
    max_tokens INT,
    search_docs_automatically BOOLEAN DEFAULT 1 NOT NULL,
    allow_web_search BOOLEAN DEFAULT 0 NOT NULL,
    allow_code_search BOOLEAN DEFAULT 0 NOT NULL,
    priority INT DEFAULT 1 NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    
    UNIQUE KEY uk_role_agent_model (role, agent_type, model_name),
    INDEX idx_role (role),
    INDEX idx_agent_type (agent_type),
    INDEX idx_model_name (model_name),
    INDEX idx_enabled (enabled),
    INDEX idx_priority (priority),
    INDEX idx_created_at (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
COMMENT='Configuration for AI models available to different user roles';

-- Create documentation_role_access table for fine-grained access control
CREATE TABLE IF NOT EXISTS documentation_role_access (
    id INT AUTO_INCREMENT PRIMARY KEY,
    role VARCHAR(100) NOT NULL,
    doc_section_pattern VARCHAR(255) NOT NULL,
    can_access BOOLEAN DEFAULT 1 NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    
    UNIQUE KEY uk_role_pattern (role, doc_section_pattern),
    INDEX idx_role (role),
    INDEX idx_doc_section_pattern (doc_section_pattern)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
COMMENT='Fine-grained role-based access control for documentation sections';
