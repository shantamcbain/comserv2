-- Add theme column to sites table if it doesn't exist
ALTER TABLE sites ADD COLUMN theme VARCHAR(50) DEFAULT 'default';

-- Create themes table
CREATE TABLE IF NOT EXISTS themes (
    id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(50) NOT NULL UNIQUE,
    description TEXT,
    base_theme VARCHAR(50) DEFAULT 'default',
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

-- Create theme_variables table table
CREATE TABLE IF NOT EXISTS theme_variables (
    id INT AUTO_INCREMENT PRIMARY KEY,
    theme_id INT NOT NULL,
    variable_name VARCHAR(50) NOT NULL,
    variable_value VARCHAR(255) NOT NULL,
    FOREIGN KEY (theme_id) REFERENCES themes(id) ON DELETE CASCADE,
    UNIQUE KEY (theme_id, variable_name)
);

-- Create site_themes table
CREATE TABLE IF NOT EXISTS site_themes (
    site_id INT NOT NULL,
    theme_id INT NOT NULL,
    is_customized BOOLEAN DEFAULT FALSE,
    PRIMARY KEY (site_id),
    FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE,
    FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE,
    FOREIGN KEY (theme_id) REFERENCES themes(id) ON DELETE RESTRICT
);

-- Insert default themes
INSERT INTO themes (name, description, base_theme) VALUES
('default', 'Default system theme', 'default'),
('usbm', 'USBM site theme', 'default'),
('csc', 'CSC site theme', 'default');

-- Insert default theme variables for the default theme
INSERT INTO theme_variables (theme_id, variable_name, variable_value) VALUES
(1, 'primary-color', '#ccffff'),
(1, 'secondary-color', '#f9f9f9'),
(1, 'accent-color', '#FF9900'),
(1, 'text-color', '#000000'),
(1, 'background-color', '#ffffff'),
(1, 'link-color', '#0000FF'),
(1, 'link-hover-color', '#000099'),
(1, 'border-color', '#cccccc'),
(1, 'table-header-bg', '#f2f2f2'),
(1, 'warning-color', '#ff0000'),
(1, 'success-color', '#009900'),
(1, 'button-bg', '#f2f2f2'),
(1, 'button-text', '#000000'),
(1, 'button-border', '#cccccc'),
(1, 'button-hover-bg', '#e0e0e0');

-- Insert default theme variables for the USBM theme
INSERT INTO theme_variables (theme_id, variable_name, variable_value) VALUES
(2, 'primary-color', '#009933'),
(2, 'secondary-color', '#FFCC66'),
(2, 'accent-color', '#FF9900'),
(2, 'text-color', '#000000'),
(2, 'background-color', '#ffffff'),
(2, 'link-color', '#000000'),
(2, 'link-hover-color', '#333333'),
(2, 'border-color', '#cccccc'),
(2, 'table-header-bg', '#FFCC66'),
(2, 'warning-color', '#ff0000'),
(2, 'success-color', '#009900'),
(2, 'button-bg', '#FFCC66'),
(2, 'button-text', '#000000'),
(2, 'button-border', '#FF9900'),
(2, 'button-hover-bg', '#FF9900');

-- Insert default theme variables for the CSC theme
INSERT INTO theme_variables (theme_id, variable_name, variable_value) VALUES
(3, 'primary-color', '#3366cc'),
(3, 'secondary-color', '#f0f0f0'),
(3, 'accent-color', '#ff6600'),
(3, 'text-color', '#333333'),
(3, 'background-color', '#ffffff'),
(3, 'link-color', '#3366cc'),
(3, 'link-hover-color', '#1a3366'),
(3, 'border-color', '#cccccc'),
(3, 'table-header-bg', '#e6e6e6'),
(3, 'warning-color', '#cc0000'),
(3, 'success-color', '#339933'),
(3, 'button-bg', '#3366cc'),
(3, 'button-text', '#ffffff'),
(3, 'button-border', '#1a3366'),
(3, 'button-hover-bg', '#1a3366');