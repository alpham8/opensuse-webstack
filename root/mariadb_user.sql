-- Create a database and a dedicated application user with full privileges.
-- Adjust the database name, username and password to match your application.

CREATE DATABASE myapp_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE USER 'myapp_user'@'localhost' IDENTIFIED BY 'changeme';
GRANT ALL PRIVILEGES ON `myapp_db`.* TO 'myapp_user'@'localhost';

FLUSH PRIVILEGES;
