-- Fix NFS paths in database to use Docker container paths
-- Run this script to update old workstation paths to container paths

-- Update nfs_directory table: /home/shanta/nfs -> /data/nfs
UPDATE nfs_directory
SET nfs_path = REPLACE(nfs_path, '/home/shanta/nfs', '/data/nfs')
WHERE nfs_path LIKE '/home/shanta/nfs%';

-- Update files table: /home/shanta/nfs -> /data/nfs
UPDATE files
SET nfs_path = REPLACE(nfs_path, '/home/shanta/nfs', '/data/nfs')
WHERE nfs_path LIKE '/home/shanta/nfs%';

UPDATE files
SET file_path = REPLACE(file_path, '/home/shanta/nfs', '/data/nfs')
WHERE file_path LIKE '/home/shanta/nfs%';

-- Show updated records
SELECT 'Updated nfs_directory:' as info;
SELECT id, sitename, nfs_path FROM nfs_directory;

SELECT 'Updated files (sample):' as info;
SELECT id, file_name, nfs_path, file_path FROM files WHERE nfs_path LIKE '/data/nfs%' OR file_path LIKE '/data/nfs%' LIMIT 10;
