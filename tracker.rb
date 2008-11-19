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
# Require the memcache gem
require 'memcache'
# Require our cache-abstraction class
require 'cache'
# Require the sinatra gem
require 'sinatra'
# Require YAML to parse config files
require 'yaml'

configure do
  # Load the config
  $config = YAML::load( open('config.yml') )
  # Connect to MySQL
  $db = Mysql::new($config[:mysql][:host], $config[:mysql][:user], $config[:mysql][:pass], $config[:mysql][:database])
  
  whitelist = $db.query( "SELECT Peer_ID, Client FROM whitelist" )
  $whitelist = Array.new
  whitelist.each_hash { |client| $whitelist << { :regex => /#{client['Peer_ID']}/, :name => client['Client'] } } # Put a RegEx of each peerid into $whitelist
end

get '/:passkey/announce' do
  begin
    # Set instance variables for all the query parameters and make sure they exist
    required_params = ['passkey', 'info_hash', 'peer_id', 'port', 'uploaded', 'downloaded', 'left']
    optional_params = ['event', 'compact', 'no_peer_id', 'ip', 'numwant']
    (required_params + optional_params).each do |param|
      error "Bad Announce" if (params[param].nil? or params[param].empty?) and required_params.include?(param)
      self.instance_variable_set("@" + param, escape(params[param]))
    end
    @event ||= 'none'
    @ip ||= escape(@ip)
    @numwant ||= 50
    
    # Make sure client is whitelisted
    whitelisted = $whitelist.map { |client| @peer_id =~ client[:regex] }.include? 0
    error "Your client is banned. Go to #{$config[:whitelist_url]}" unless whitelisted
    
    # Instantiate a cache object for this request
    cache = Cache.new(:host => $config[:cache][:host], :namespace => $config[:cache][:namespace], :passkey => @passkey, :peer_id => @peer_id, :info_hash => @info_hash)
    
    # Find our user
    user = cache.user
    error "Account not found" unless user.exists?
    error "Leeching Disabled" unless user.can_leech?
    
    # Find our torrent
    torrent = cache.torrent
    error "Torrent not found" unless torrent.exists?
    
    # Find peers
    peers = torrent.peers[0, @numwant]
        
    # Log Announce
    $db.query( "INSERT INTO tracker_announce_log (UserID, TorrentID, IP, Port, Event, Uploaded, Downloaded, tracker_announce_log.Left, PeerID, RequestURI, Time) VALUES (#{user['ID']}, #{torrent['ID']}, '#{@ip}', #{@port}, '#{@event}', #{@uploaded}, #{@downloaded}, #{@left}, '#{@peer_id}', '#{escape request.env['QUERY_STRING']}', NOW())" ) if $config[:log_announces]
    
    # Generate Peerlist
    if @compact == '1' # Compact Mode
      peer_list = ''
      peers.each do |peer| # Go through each peer
        ip = peer['IP'].split('.').collect { |octet| octet.to_i }.pack('C*')
        port = [peer['Port'].to_i].pack('n*')
        peer_list << ip + port
      end
    else
      peer_list = []
      peers.each do |peer| # Go through each peer
        peer_hash = { 'ip' => peer['IP'], 'port' => peer['Port'] }
        peer_hash.update( { 'peer id' => peer['PeerID'] } ) unless @no_peer_id == 1
        peer_list << peer_hash
      end
    end
    
    @resp = { 'interval' => $config[:announce_int], 'min interval' => $config[:min_announce_int], 'peers' => peer_list }
    # End peerlist generation
    
    # Update database / cache
    # Update values specific to each event
    case @event
    when 'started'
      # Add the user to the torrents peerlist, then update the seeder / leecher count
      torrent.new_peer(@ip, @port, @left, @peer_id)
      $db.query( "UPDATE torrents SET #{@left.to_i > 0 ? 'Leechers = Leechers + 1' : 'Seeders = Seeders + 1'} WHERE ID = #{torrent['ID']}" )
    when 'completed'
      $db.query( "INSERT INTO tracker_snatches (UserID, TorrentID, IP, Port, Uploaded, Downloaded, PeerID) VALUES (#{user['ID']}, #{torrent['ID']}, '#{@ip}', #{@port}, #{@uploaded}, #{@downloaded}, '#{@peer_id}')" )
      $db.query( "UPDATE torrents SET Seeders = Seeders + 1, Leechers = Leechers - 1, Snatched = Snatched + 1 WHERE ID = #{torrent['ID']}" )
    when 'stopped'
      # Update Seeder / Leecher count for torrent, and update snatched list with final upload / download counts, then delete the user from the torrents peerlist
      $db.query( "UPDATE torrents AS t, tracker_snatches AS s SET #{@left.to_i > 0 ? 't.Leechers = t.Leechers - 1' : 't.Seeders = t.Seeders - 1'}, s.Uploaded = #{@uploaded}, s.Downloaded = #{@downloaded} WHERE t.ID = #{torrent['ID']} AND (s.UserID = #{user['ID']} AND s.TorrentID = #{torrent['ID']})" )
      torrent.delete_peer
    end
    
    # Add user to the update queue
    user.update(@uploaded, @downloaded, @left)
    
    @resp.bencode
  rescue TrackerError => e
    e.message
  end
end

get '/:passkey/scrape' do
  error "Bad Scrape" if params['info_hash'].nil? or params['info_hash'].empty?
  cache = MemCache::new $config[:cache][:host], :namespace => $config[:cache][:namespace]
  torrent = Cache::Torrent.new(cache, $db, params['info_hash'])
  
  { params['info_hash'] => { 'complete' => torrent['Seeders'], 'incomplete' => torrent['Leechers'], 'downloaded' => torrent['Snatched'], 'name' => torrent['Name'] } }.bencode
end

get '/whitelist' do
  $whitelist.collect { |client| client[:name] }.join('<br />')
end

helpers do
  def error reason
    raise TrackerError, { 'failure reason' => reason }.bencode
  end
  def escape string
    Mysql::escape_string(string.to_s)
  end
end

# Error class
class TrackerError < RuntimeError; end # Used to clearly identify errors