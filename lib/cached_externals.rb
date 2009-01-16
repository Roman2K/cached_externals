require 'capistrano/recipes/deploy/scm/base'

Capistrano::Deploy::SCM::Base.class_eval do
  def perform_remote_checkout(context, revision, destination)
    context.run("if [ ! -d #{destination} ]; then (#{checkout(revision, destination)}) || rm -rf #{destination}; fi")
  end
end

module CachedExternals
  module Modules
    extend self
    
    CACHE_DIR_KEY   = 'cache_directory'
    GLOBAL_DEF_PATH = "#{ENV['HOME']}/.cached_externals.yml"
    
    def all
      modules = data
      modules.delete(CACHE_DIR_KEY)
      modules.each do |path, options|
        strings = options.keys.grep(String)
        raise ArgumentError, "the externals.yml file must use symbols for the option keys (found #{strings.inspect} under #{path})" if strings.any?
      end
    end
    
    def cache_directory
      data[CACHE_DIR_KEY] || "../shared/externals"
    end
    
  private
  
    def data
      @data ||= begin
        require 'erb'
        require 'yaml'
        contents = File.read("config/externals.yml") rescue ""
        if File.file?(GLOBAL_DEF_PATH)
          puts "Loading global externals definition from: #{GLOBAL_DEF_PATH}"
          contents = File.read(GLOBAL_DEF_PATH) + "\n" + contents
        end
        app_name = File.basename(Dir.pwd)
        contents = ERB.new(contents).result(binding)
        YAML.load(contents) || {}
      end
    end
  end
  
  class LocalSCM
    def initialize(configuration)
      @repository = configuration[:repository]
    end
    
    def command
      nil
    end
    
    def checkout(revision, destination)
      "ln -nsf #{File.expand_path(@repository)} #{destination}"
    end

    def perform_remote_checkout(context, revision, destination)
      context.execute_on_servers do |servers|
        servers.each do |server|
          Checkout.new(context.sessions[server], @repository, destination, context.logger).start
        end
      end
    end

    def query_revision(revision)
      define_checksum_func = "if which md5 > /dev/null 2>&1; then SUM=md5; else checksum() { md5sum | awk '{ print $1 }'; }; SUM=checksum; fi"
      structure_checksum = "find #{@repository} | $SUM"
      content_checksum = "find #{@repository} -type f -print0 | xargs -0 cat | $SUM"
      query_command = "#{define_checksum_func}; echo \"$(#{structure_checksum})$(#{content_checksum})\" | $SUM"
      yield(query_command).chomp
    end

    class Checkout
      def initialize(session, repository, destination, logger)
        @session, @sftp = session, nil
        @repository, @destination = repository, destination
        @logger = logger
      end

      def start
        @sftp = @session.sftp(false).connect!
        begin
          perform
        ensure
          @sftp.close_channel
        end
      end

    private

      def archive
        @archive ||= "#{File.basename(@repository)}-#{File.basename(@destination)}.tgz"
      end

      def local_archive
        @local_archive ||= File.join(Dir.tmpdir, archive)
      end

      def remote_archive
        @remote_archive ||= File.join('/tmp', archive)
      end

    private

      def perform
        if destination_exist?
          @logger.info "already exists, skipping: #{@destination}"
          return
        end

        @logger.debug "creating local archive: #{archive}"
        Dir.chdir(File.dirname(@repository)) do
          system("tar czf #{local_archive} #{File.basename(@repository)}")
        end

        @logger.debug "uploading: #{archive}"
        @sftp.upload!(local_archive, remote_archive)

        command = "cd #{File.dirname(@destination)} && tar xzf #{remote_archive} && mv #{File.basename(@repository)} #{File.basename(@destination)}; rm #{remote_archive}"
        @logger.debug "executing: #{command}"
        @session.exec!(command)
      end

      def destination_exist?
        @sftp.lstat!(@destination)
        true
      rescue Net::SFTP::StatusException
        false
      end
    end
  end
end
