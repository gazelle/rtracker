--
-- Table structure for table `tracker_peers`
--

DROP TABLE IF EXISTS `tracker_peers`;
CREATE TABLE `tracker_peers` (
   `ID` int(11) auto_increment,
   `UserID` int(10) unsigned,
   `TorrentID` int(10) unsigned,
   `IP` varchar(15),
   `Port` int(5),
   `Uploaded` bigint(20),
   `Downloaded` bigint(20),
   `Left` bigint(20),
   `PeerID` char(20),
   `Time` timestamp,
   PRIMARY KEY (`ID`)
) ENGINE=InnoDB DEFAULT CHARSET utf8;

--
-- Table structure for table `tracker_announce_log`
--

DROP TABLE IF EXISTS `tracker_announce_log`;
CREATE TABLE `tracker_announce_log` (
  `ID` int(11) auto_increment,
  `UserID` int(10) unsigned NOT NULL,
  `TorrentID` int(10) unsigned NOT NULL,
  `IP` varchar(15) NOT NULL,
  `Port` int(5) NOT NULL,
  `Event` varchar(10) NOT NULL,
  `Uploaded` bigint(20) NOT NULL,
  `Downloaded` bigint(20) NOT NULL,
  `Left` bigint(20) NOT NULL,
  `PeerID` char(20) NOT NULL,
  `Time` datetime NOT NULL,
  `RequestURI` varchar(400) NOT NULL default '',
  PRIMARY KEY  (`ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;


--
-- Table structure for table `tracker_snatches`
--

DROP TABLE IF EXISTS `tracker_snatches`;
CREATE TABLE `tracker_snatches` (
   `ID` int(11) auto_increment,
   `UserID` int(10) unsigned,
   `TorrentID` int(10) unsigned,
   `TrackerID` int(11),
   `IP` varchar(15),
   `Port` int(5),
   `Uploaded` bigint(20),
   `Downloaded` bigint(20),
   `PeerID` char(20),
   `Time` timestamp,
   PRIMARY KEY (`TrackerID`)
) ENGINE=InnoDB DEFAULT CHARSET utf8;