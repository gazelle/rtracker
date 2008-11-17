##################################################################
## Ruby BitTorrent Tracker                                      ##
##                                                              ##
##                                                              ##
## Copyright 2008 Vars                                          ##
## Released under the Creative Commons Attribution License      ##
##################################################################

# Require RubyGems
require 'rubygems'
# Require the bencode gem from http://github.com/dasch/ruby-bencode-bindings/tree/master
require 'bencode'
# Require the mysql gem
require 'mysql'
# Require the sinatra gem
require 'sinatra'
# Require YAML to parse config files
require 'yaml'

configure do
  # Load the config
  $config = YAML::load( open('config.yml') )
  # Connect to MySQL
  $db = Mysql::new($config[:mysql][:host], $config[:mysql][:user], $config[:mysql][:pass], $config[:mysql][:database]

  whitelist = $db.query( "SELECT Peer_ID FROM whitelist" )
  $whitelist = Array.new
  whitelist.each_hash { |client| $whitelist << /#{client['Peer_ID']}/ } # Put a RegEx of each peerid into $whitelist
end

get '/:passkey/announce' do
  begin
    # Set instance variables for all the query parameters and make sure they exist
    required_params = ['passkey', 'info_hash', 'peer_id', 'port', 'uploaded', 'downloaded', 'left']
    optional_params = ['event', 'compact', 'no_peer_id', 'ip', 'numwant']
    (required_params + optional_params).each do |param|
      error "Bad Announce" if (params[param].nil? or params[param].empty?) and required_params.include?(param)
      self.instance_variable_set("@" + param, params[param])
    end
    @numwant ||= 50
    @event ||= 'none'
    
    # Make sure client is whitelisted
    whitelisted = $whitelist.map { |client| @peer_id =~ client }.include? 0
    error "Your client is banned. Go to #{$config[:whitelist_url]}" unless whitelisted

    # Find our user
    user = $db.query( "SELECT um.ID, um.Enabled, um.can_leech, p.Level FROM users_main AS um LEFT JOIN permissions AS p ON um.PermissionID=p.ID WHERE torrent_pass = '#{escape(@passkey)}'" ).fetch_hash
    error "Account not found" if user.nil? or user['Enabled'] != '1'
    error "Leeching Disabled" if user['can_leech'] != '1' and @left != 0
    
    # Find our torrent
    torrent = $db.query( "SELECT t.ID, t.FreeTorrent FROM torrents AS t WHERE t.info_hash = '#{escape(@info_hash)}'" ).fetch_hash
    error "Torrent not found" if torrent.nil?
    
    # Find peers
    peers = $db.query( "SELECT p.UserID, p.IP, p.Port, p.PeerID FROM tracker_peers AS p WHERE TorrentID = '#{torrent['ID']}' ORDER BY RAND() LIMIT #{@numwant.to_i}" )
    
    # Log Announce
    $db.query( "INSERT INTO tracker_announce_log (UserID, TorrentID, IP, Port, Event, Uploaded, Downloaded, tracker_announce_log.Left, PeerID, RequestURI, Time) VALUES (#{user['ID']}, #{torrent['ID']}, '#{escape request.env['REMOTE_ADDR']}', #{escape @port}, '#{escape @event}', #{escape @uploaded}, #{escape @downloaded}, #{escape @left}, '#{escape @peer_id}', '#{escape request.env['QUERY_STRING']}', NOW())" ) if $config[:log_announces]
    
    # Generate Peerlist
    peer_list = []
    peer_list_compact = ''
    peers.each_hash do |peer| # Go through each peer
      if @compact == '1' # Compact Mode
        ip = peer['IP'].split('.').collect { |octet| octet.to_i }.pack('C*')
        port = [peer['Port'].to_i].pack('n*')
        peer_list_compact << ip + port
      else # Normal Mode
        peer_hash = { 'ip' => peer['IP'], 'port' => peer['Port'] }
        peer_hash.update( { 'peer id' => peer['PeerID'] } ) unless @no_peer_id == 1
         peer_list << peer_hash
      end
    end
    
    if @compact == '1' # Compact Mode
      @resp = { 'interval' => $config[:announce_int], 'min interval' => $config[:min_announce_int], 'peers' => peer_list_compact }
    else
      @resp = { 'interval' => $config[:announce_int], 'min interval' => $config[:min_announce_int], 'peers' => peer_list }
    end
    # End peerlist generation
    
    # Update database
    # Update values specific to each event
    case @event
    when 'started'
      # Add the user to the torrents peerlist, then update the seeder / leecher count
      $db.query( "INSERT INTO tracker_peers (UserID, TorrentID, IP, Port, Uploaded, Downloaded, tracker_peers.Left, PeerID) VALUES (#{user['ID']}, #{torrent['ID']}, '#{escape request.env['REMOTE_ADDR']}', '#{escape @port}', 0, 0, #{escape @left}, '#{escape @peer_id}')" )
      $db.query( "UPDATE torrents SET #{@left.to_i > 0 ? 'Leechers = Leechers + 1' : 'Seeders = Seeders + 1'} WHERE ID = #{torrent['ID']}" )
    when 'completed'
      $db.query( "INSERT INTO tracker_snatches (UserID, TorrentID, IP, Port, Uploaded, Downloaded, PeerID) VALUES (#{user['ID']}, #{torrent['ID']}, '#{escape request.env['REMOTE_ADDR']}', #{escape @port}, #{escape @uploaded}, #{escape @downloaded}, '#{escape @peer_id}')" )
      $db.query( "UPDATE torrents SET Seeders = Seeders + 1, Leechers = Leechers - 1, Snatched = Snatched + 1 WHERE ID = #{torrent['ID']}" )
    when 'stopped'
      # Update Seeder / Leecher count for torrent, and update snatched list with final upload / download counts, then delete the user from the torrents peerlist
      $db.query( "UPDATE torrents AS t, tracker_snatches AS s SET #{@left.to_i > 0 ? 't.Leechers = t.Leechers - 1' : 't.Seeders = t.Seeders - 1'}, s.Uploaded = #{escape @uploaded}, s.Downloaded = #{escape @downloaded} WHERE t.ID = #{torrent['ID']} AND (s.UserID = #{user['ID']} AND s.TorrentID = #{torrent['ID']})" )
      $db.query( "DELETE FROM tracker_peers WHERE PeerID = '#{escape @peer_id}' AND TorrentID = #{torrent['ID']}" )
    end
    
    # Update uploaded / downloaded / left amounts
    # This is two queries because we need the old p.Uploaded value to find out what they've uploaded since the last announce, and when it's one query, it uses the current uploaded amount, which is useless since @uploaded - @uploaded = 0, and the user's ratio would never update
    $db.query( "UPDATE users_main AS u, tracker_peers AS p SET u.Uploaded=u.Uploaded+#{escape @uploaded}-p.Uploaded, u.Downloaded=u.Downloaded+#{escape @downloaded}-p.Downloaded WHERE (p.PeerID='#{escape @peer_id}' AND u.ID=#{user['ID']} AND p.TorrentID=#{torrent['ID']})" )
    $db.query( "UPDATE tracker_peers AS p SET p.Uploaded = #{escape @uploaded}, p.Downloaded = #{escape @downloaded}, p.Left = #{escape @left} WHERE p.PeerID = '#{escape @peer_id}' AND TorrentID = #{torrent['ID']}" )
    # End database update
    
    @resp.bencode
  rescue TrackerError => e
    e.message
  end
end

get '/:passkey/scrape' do
  {}.bencode
end

helpers do
  def error reason
    raise TrackerError, { 'failure reason' => reason }.bencode
  end
  def escape string
    Mysql::escape_string(string.to_s)
  end
end

# Error Class
class TrackerError < RuntimeError; end