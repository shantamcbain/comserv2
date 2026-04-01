
SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";
SET time_zone = "+00:00";


/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!40101 SET NAMES utf8 */;

--
-- Database: `shanta_forager`
--
CREATE DATABASE IF NOT EXISTS `shanta_forager` DEFAULT CHARACTER SET latin1 COLLATE latin1_swedish_ci;
USE `shanta_forager`;

CREATE TABLE IF NOT EXISTS `item_tb` (
  `record_id` int(11) NOT NULL AUTO_INCREMENT,
  `item_code` varchar(20) NOT NULL DEFAULT '',
  `status` varchar(30) NOT NULL DEFAULT '',
  `sitename` varchar(20) DEFAULT NULL,
  `comments` text,
  `discription` text,
  `amps` tinyint(4) NOT NULL,
  `volts`tinyint(4) NOT NULL,
  `Manufacture` varchar(25) NOT NULL DEFAULT '',
  `Mproduct_code` varchar(20) NOT NULL '',
  `suppler` varchar(100) NOT NULL DEFAULT '',
  `price` int(5.2) NOT NULL DEFAULT '',
  `fuelconsuption varchar(20) NOT NULL '',
  `developer_name` varchar(50) NOT NULL DEFAULT '',
  `client_name` varchar(50) NOT NULL DEFAULT '',
  `due_date` date NOT NULL DEFAULT '0000-00-00',
  `username_of_poster` varchar(30) NOT NULL DEFAULT '',
  `group_of_poster` varchar(30) NOT NULL DEFAULT '',
  `date_time_posted` varchar(30) NOT NULL DEFAULT '',
  PRIMARY KEY (`record_id`,`item_code`)
) ENGINE=MyISAM  DEFAULT CHARSET=latin1 AUTO_INCREMENT=80 ;
