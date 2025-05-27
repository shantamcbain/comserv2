#!/usr/bin/env python3
"""
CloudflareManager.py - Role-based Cloudflare API access control for Comserv2

This module integrates with the existing Comserv2 site and user management system
to provide role-based access control for Cloudflare API operations.

It uses the Cloudflare Python SDK and respects the existing site and user roles
from the Comserv2 database.
"""

import json
import os
import sys
import logging
from typing import List, Dict, Any, Optional, Union
import CloudFlare

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler("/var/log/comserv2/cloudflare.log"),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger("CloudflareManager")

class CloudflareRoleManager:
    """
    Manages role-based access to Cloudflare API operations.
    Integrates with the existing Comserv2 site and user management system.
    """
    
    def __init__(self, config_path: str = None):
        """
        Initialize the CloudflareRoleManager.
        
        Args:
            config_path: Path to the configuration file. If None, uses the default path.
        """
        if config_path is None:
            # Default config path relative to this file
            base_dir = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
            config_path = os.path.join(base_dir, 'config', 'cloudflare_config.json')
        
        try:
            with open(config_path, 'r') as f:
                self.config = json.load(f)
            
            # Initialize Cloudflare client
            self.cf = CloudFlare.CloudFlare(
                token=self.config['cloudflare']['api_token'],
                email=self.config['cloudflare']['email']
            )
            
            # Cache for zone IDs to avoid repeated API calls
            self.zone_id_cache = {}
            
            logger.info("CloudflareRoleManager initialized successfully")
        except Exception as e:
            logger.error(f"Failed to initialize CloudflareRoleManager: {str(e)}")
            raise
    
    def get_user_permissions(self, user_email: str, domain: str) -> List[str]:
        """
        Get the permissions for a user on a specific domain.
        
        Args:
            user_email: The email of the user
            domain: The domain to check permissions for
            
        Returns:
            List of permission strings the user has for this domain
        """
        # This would normally query your database to get the user's role
        # For demonstration, we'll use a simple lookup
        # In production, you would integrate with your existing user system
        
        # Get user role from database (placeholder)
        user_role = self._get_user_role_from_db(user_email)
        
        if not user_role:
            logger.warning(f"No role found for user {user_email}")
            return []
        
        # Get base permissions for the role
        base_permissions = self.config['roles'].get(user_role, {}).get('permissions', [])
        
        # Check for site-specific permission overrides
        site_specific = self.config.get('site_specific_permissions', {}).get(domain, {})
        if user_role in site_specific:
            return site_specific[user_role]
        
        return base_permissions
    
    def _get_user_role_from_db(self, user_email: str) -> Optional[str]:
        """
        Get the user's role from the database.
        
        In a real implementation, this would query your database.
        For this example, we'll return a placeholder role.
        
        Args:
            user_email: The email of the user
            
        Returns:
            The role of the user, or None if not found
        """
        # This is a placeholder. In production, you would:
        # 1. Connect to your database
        # 2. Query the users table to get the user's roles
        # 3. Return the appropriate role
        
        # Example of how you might integrate with your existing system:
        # from Comserv.Model.User import User
        # user = User.get_by_email(user_email)
        # return user.get_primary_role()
        
        # For demonstration, we'll use a simple mapping
        email_to_role = {
            "admin@example.com": "admin",
            "developer@example.com": "developer",
            "editor@example.com": "editor",
            "bmaster_user@example.com": "editor"
        }
        
        return email_to_role.get(user_email)
    
    def check_permission(self, user_email: str, domain: str, action: str) -> bool:
        """
        Check if a user has permission to perform an action on a domain.
        
        Args:
            user_email: The email of the user
            domain: The domain to check permissions for
            action: The action to check (e.g., "dns:edit")
            
        Returns:
            True if the user has permission, False otherwise
            
        Raises:
            PermissionError: If the user doesn't have permission
        """
        permissions = self.get_user_permissions(user_email, domain)
        
        # Check if the user has the required permission
        if action not in permissions:
            logger.warning(f"User {user_email} does not have {action} permission for {domain}")
            raise PermissionError(f"User {user_email} does not have permission to {action} on {domain}")
        
        logger.info(f"User {user_email} has {action} permission for {domain}")
        return True
    
    def get_zone_id(self, domain: str) -> Optional[str]:
        """
        Get the Cloudflare zone ID for a domain.
        
        Args:
            domain: The domain to get the zone ID for
            
        Returns:
            The zone ID, or None if not found
        """
        # Check cache first
        if domain in self.zone_id_cache:
            return self.zone_id_cache[domain]
        
        try:
            # Query Cloudflare API
            zones = self.cf.zones.get(params={'name': domain})
            
            if not zones:
                logger.warning(f"No zone found for domain {domain}")
                return None
            
            zone_id = zones[0]['id']
            
            # Cache the result
            self.zone_id_cache[domain] = zone_id
            
            return zone_id
        except Exception as e:
            logger.error(f"Error getting zone ID for {domain}: {str(e)}")
            return None
    
    def get_domains_for_site(self, site_name: str) -> List[str]:
        """
        Get all domains associated with a site.
        
        In a real implementation, this would query your database.
        
        Args:
            site_name: The name of the site
            
        Returns:
            List of domains associated with the site
        """
        # This is a placeholder. In production, you would:
        # 1. Connect to your database
        # 2. Query the SiteDomain table to get domains for the site
        # 3. Return the list of domains
        
        # Example of how you might integrate with your existing system:
        # from Comserv.Model.Site import Site
        # site = Site.get_by_name(site_name)
        # return [domain.domain for domain in site.domains]
        
        # For demonstration, we'll use a simple mapping
        site_to_domains = {
            "CSC": ["csc.example.com", "comserv.example.com"],
            "BMaster": ["beemaster.ca", "beemaster.example.com"]
        }
        
        return site_to_domains.get(site_name, [])
    
    def list_dns_records(self, user_email: str, domain: str) -> List[Dict[str, Any]]:
        """
        List DNS records for a domain.
        
        Args:
            user_email: The email of the user making the request
            domain: The domain to list DNS records for
            
        Returns:
            List of DNS records
            
        Raises:
            PermissionError: If the user doesn't have permission
        """
        # Check permission
        self.check_permission(user_email, domain, "dns:edit")
        
        # Get zone ID
        zone_id = self.get_zone_id(domain)
        if not zone_id:
            logger.error(f"Could not find zone ID for domain {domain}")
            return []
        
        try:
            # Query Cloudflare API
            dns_records = self.cf.zones.dns_records.get(zone_id)
            return dns_records
        except Exception as e:
            logger.error(f"Error listing DNS records for {domain}: {str(e)}")
            return []
    
    def create_dns_record(self, user_email: str, domain: str, record_type: str, 
                         name: str, content: str, ttl: int = 1, proxied: bool = False) -> Dict[str, Any]:
        """
        Create a DNS record.
        
        Args:
            user_email: The email of the user making the request
            domain: The domain to create the DNS record for
            record_type: The type of DNS record (A, CNAME, etc.)
            name: The name of the record
            content: The content of the record
            ttl: The TTL of the record
            proxied: Whether the record is proxied
            
        Returns:
            The created DNS record
            
        Raises:
            PermissionError: If the user doesn't have permission
        """
        # Check permission
        self.check_permission(user_email, domain, "dns:edit")
        
        # Get zone ID
        zone_id = self.get_zone_id(domain)
        if not zone_id:
            logger.error(f"Could not find zone ID for domain {domain}")
            raise ValueError(f"Could not find zone ID for domain {domain}")
        
        try:
            # Create DNS record
            dns_record = {
                'type': record_type,
                'name': name,
                'content': content,
                'ttl': ttl,
                'proxied': proxied
            }
            
            result = self.cf.zones.dns_records.post(zone_id, data=dns_record)
            logger.info(f"Created DNS record {name} for {domain}")
            return result
        except Exception as e:
            logger.error(f"Error creating DNS record for {domain}: {str(e)}")
            raise
    
    def update_dns_record(self, user_email: str, domain: str, record_id: str, 
                         record_type: str, name: str, content: str, 
                         ttl: int = 1, proxied: bool = False) -> Dict[str, Any]:
        """
        Update a DNS record.
        
        Args:
            user_email: The email of the user making the request
            domain: The domain to update the DNS record for
            record_id: The ID of the record to update
            record_type: The type of DNS record (A, CNAME, etc.)
            name: The name of the record
            content: The content of the record
            ttl: The TTL of the record
            proxied: Whether the record is proxied
            
        Returns:
            The updated DNS record
            
        Raises:
            PermissionError: If the user doesn't have permission
        """
        # Check permission
        self.check_permission(user_email, domain, "dns:edit")
        
        # Get zone ID
        zone_id = self.get_zone_id(domain)
        if not zone_id:
            logger.error(f"Could not find zone ID for domain {domain}")
            raise ValueError(f"Could not find zone ID for domain {domain}")
        
        try:
            # Update DNS record
            dns_record = {
                'type': record_type,
                'name': name,
                'content': content,
                'ttl': ttl,
                'proxied': proxied
            }
            
            result = self.cf.zones.dns_records.put(zone_id, record_id, data=dns_record)
            logger.info(f"Updated DNS record {name} for {domain}")
            return result
        except Exception as e:
            logger.error(f"Error updating DNS record for {domain}: {str(e)}")
            raise
    
    def delete_dns_record(self, user_email: str, domain: str, record_id: str) -> Dict[str, Any]:
        """
        Delete a DNS record.
        
        Args:
            user_email: The email of the user making the request
            domain: The domain to delete the DNS record from
            record_id: The ID of the record to delete
            
        Returns:
            The response from the Cloudflare API
            
        Raises:
            PermissionError: If the user doesn't have permission
        """
        # Check permission
        self.check_permission(user_email, domain, "dns:edit")
        
        # Get zone ID
        zone_id = self.get_zone_id(domain)
        if not zone_id:
            logger.error(f"Could not find zone ID for domain {domain}")
            raise ValueError(f"Could not find zone ID for domain {domain}")
        
        try:
            # Delete DNS record
            result = self.cf.zones.dns_records.delete(zone_id, record_id)
            logger.info(f"Deleted DNS record {record_id} for {domain}")
            return result
        except Exception as e:
            logger.error(f"Error deleting DNS record for {domain}: {str(e)}")
            raise
    
    def purge_cache(self, user_email: str, domain: str) -> Dict[str, Any]:
        """
        Purge the cache for a domain.
        
        Args:
            user_email: The email of the user making the request
            domain: The domain to purge the cache for
            
        Returns:
            The response from the Cloudflare API
            
        Raises:
            PermissionError: If the user doesn't have permission
        """
        # Check permission
        self.check_permission(user_email, domain, "cache:edit")
        
        # Get zone ID
        zone_id = self.get_zone_id(domain)
        if not zone_id:
            logger.error(f"Could not find zone ID for domain {domain}")
            raise ValueError(f"Could not find zone ID for domain {domain}")
        
        try:
            # Purge cache
            purge_data = {'purge_everything': True}
            result = self.cf.zones.purge_cache.post(zone_id, data=purge_data)
            logger.info(f"Purged cache for {domain}")
            return result
        except Exception as e:
            logger.error(f"Error purging cache for {domain}: {str(e)}")
            raise


# Example usage
if __name__ == "__main__":
    # This is a simple example of how to use the CloudflareRoleManager
    # In a real application, you would integrate this with your existing system
    
    try:
        manager = CloudflareRoleManager()
        
        # Example: List DNS records for a domain
        user_email = "admin@example.com"
        domain = "example.com"
        
        print(f"Checking if {user_email} can edit DNS for {domain}...")
        try:
            manager.check_permission(user_email, domain, "dns:edit")
            print(f"User {user_email} has permission to edit DNS for {domain}")
            
            # Get zone ID
            zone_id = manager.get_zone_id(domain)
            print(f"Zone ID for {domain}: {zone_id}")
            
            # List DNS records
            dns_records = manager.list_dns_records(user_email, domain)
            print(f"Found {len(dns_records)} DNS records for {domain}")
            
        except PermissionError as e:
            print(f"Permission denied: {str(e)}")
        
    except Exception as e:
        print(f"Error: {str(e)}")