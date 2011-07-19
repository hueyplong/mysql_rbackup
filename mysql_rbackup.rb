#!/usr/bin/env ruby
# MySQL backup script
# kirk@dostuffmedia.com
# ---------------------------------------------------------------------

require 'optparse'

##################################################
#  CONFIGURABLES:
#  Adjust as necessary.

#  database info, 
#  'db_name, db_user, db_pass'
DATABASE_LIST = [
  'DB_NAME, DB_USER, DB_PASS',
]

#  local backup dir
#  make sure it exists and is writable.
BACKUP_DIRECTORY = "/full/path/to/local/backup/dir"

#  temp dir (don't use /tmp, should be a 'workspace' temp dir near the local backup dir)
#  make sure it exists and is writable.
TEMP_DIRECTORY = "/full/path/to/local/workspace/dir"

#  remote scp info
#  'user@host:folder, port'
SCP_HOSTS = [
  'USER@HOST:BACKUP_DIR, 22',
]

#  local count
#  how many files to keep in the local backup directory
LOCAL_COUNT = 30

##################################################
#               A NOTE ON SCP:
#  To set up SCP remote backups, you must config.
#  ssh to connect w/o a password.  This is done
#  safely and securely via the exchange of public
#  and private keys.  Directions on how to do
#  this can be found on the web.  LINK:
#
#  http://gentoo-wiki.com/SECURITY_SSH_without_a_password
#
#     They are summarized below:
#      --on the local machine:
#  1% ssh-keygen -t rsa   # press enter for all.
#  2% scp ~/.ssh/id_rsa.pub you@remotehost:.ssh/id_rsa.pub
#     --log onto remote host:
#  3% ssh you@remotehost
#  4% cd .ssh; cat id_rsa.pub >> authorized_keys
#  5% chmod 600 authorized_keys; rm id_rsa.pub
#  6% exit
#     --back on local machine try:
#  7% ssh you@remotehost
#
#  to add multiple remote hosts, simply start
#  at line 2 (no need to rerun ssh-keygen).
##################################################


class MysqlRbackup
  
  attr_accessor :database_list, :backup_directory, :temp_directory, :scp_hosts, :local_count, :options, :total_databases, :total_hosts
  
  DATE = Time.now.strftime("%Y-%m-%d") 
  TIME = Time.now.strftime("%H%M")
  
  def initialize
    self.database_list = DATABASE_LIST
    self.backup_directory = BACKUP_DIRECTORY
    self.temp_directory = TEMP_DIRECTORY
    self.scp_hosts = SCP_HOSTS
    self.local_count = LOCAL_COUNT
    self.total_databases = database_list.count
    self.total_hosts = scp_hosts.count
    self.options = parse_options(ARGV)
    prepare_workspace
    run_backups
  end
  
  def parse_options(args)
    options = {}
    OptionParser.new do |opts|
      opts.banner = "Usage: mysql_rbackup.rb [options]"
    
      opts.on("-v", "--[no-]verbose", "Run verbosely") do |v|
        options[:verbose] = v
      end
      
      opts.on("-s", "--slave", "Start / stop the slave (for backups on a slave db)") do |s|
        options[:slave] = s
      end
    
    end.parse!
    return options
  end
  
  # Check for the local backup directory and trim as necessary
  def prepare_workspace
    # create the local backup directory if it doesn't exist
    puts "Checking workspace..." if options[:verbose]
    unless File.directory?(backup_directory)
      Dir.mkdir(backup_directory)
    end
    unless File.directory?(temp_directory)
      Dir.mkdir(temp_directory)
    end
    Dir.chdir(backup_directory)
    # check local count against existing backups and delete if needed
    puts "Checking and clearing archives..." if options[:verbose]
    backup_files = Dir.glob('*').sort_by{ |f| File.ctime(f) }
    if (backup_files.count > (local_count * total_databases))
      number_to_remove = backup_files.count - (local_count * total_databases)
      backup_files.slice(0, number_to_remove).each { |f| File.delete(f) }
    end
  end
  
  # Run the backups and tar/gzip the results
  def run_backups
    puts "Starting backups..." if options[:verbose]
    for database in database_list
      Dir.chdir(temp_directory)
      name, user, pass = database.split(",")
      password = pass.strip.empty? ? '' : "-p#{pass}"
      tgz_filename = "#{name}.#{DATE}.#{TIME}.tgz"
      # stop the slave if necessary
      puts "Stopping the slave..." if options[:verbose] && options[:slave]
      exec "mysql -u #{user} #{password} --execute='stop slave;'" if options[:slave]
      
      # switch to the current database and backup each table
      tables = `echo 'show tables' | mysql -u #{user} #{password} #{name} | grep -v Tables_in_`
      for table in tables
        table.strip!
        puts "Backing up table #{table}..." if options[:verbose]
        filename = "#{table}.#{DATE}.#{TIME}.sql"
        `mysqldump --add-drop-table --allow-keywords -q -c -u #{user} #{password} #{name} #{table} > #{filename}`
      end
      
      # restart the slave if necessary
      puts "Restarting the slave..." if options[:verbose] && options[:slave]
      exec "mysql -u #{user} #{password} --execute='start slave;'" if options[:slave]
      
      # zip it up and move it to the backup directory
      puts "Completed backups, zipping it up..." if options[:verbose]
      `tar -zcvf #{backup_directory}/#{tgz_filename} *`
      puts "Cleaning up..." if options[:verbose]
      Dir.chdir(backup_directory)
      `rm -rf #{temp_directory}`
      
      # copy it to any remote hosts if needed
      scp_results(tgz_filename) unless scp_hosts.empty?
      puts "And we're done!" if options[:verbose]
    end
  end
  
  # Copy the files to any remote hosts
  def scp_results(filename)
    for scp_host in scp_hosts
      host, port = scp_host.split(",")
      puts "Copying file to host #{host}..." if options[:verbose]
      `scp -r -P #{port.strip} #{filename} #{host}`
    end
  end
  
end

backup = MysqlRbackup.new
