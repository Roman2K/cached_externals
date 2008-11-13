require 'capistrano/recipes/deploy/scm/base'

Capistrano::Deploy::SCM::Base.class_eval do
  def perform_remote_checkout(context, revision, destination)
    context.run("if [ ! -d #{destination} ]; then (#{checkout(revision, destination)}) || rm -rf #{destination}; fi")
  end
end

class LocalSCM < Capistrano::Deploy::SCM::Base
  def head
    ""
  end

  def checkout(revision, destination)
    "ln -nsf #{File.expand_path(repository)} #{destination}"
  end

  def perform_remote_checkout(context, revision, destination)
    context.execute_on_servers do |servers|
      operations = servers.map do |server|
        on_error = lambda { |message| logger.important(message, server) }
        Checkout.new(sessions[server], repository, destination, on_error).start
      end
      operations.each { |op| op.wait } 
    end
  end

  def query_revision(revision)
    structure_checksum = "find #{repository} | md5"
    content_checksum   = "find #{repository} -type f -print0 | xargs -0 cat | md5"
    yield("echo \"$(#{structure_checksum})$(#{content_checksum})\" | md5").chomp
  end

  class Checkout
    def initialize(session, repository, destination, on_error)
      @session, @sftp = session, nil
      @repository, @destination = repository, destination
      @on_error = on_error
      @complete = false
    end

    def start
      @session.sftp(false).connect do |sftp|
        @sftp = sftp
        perform do
          @complete = true
        end
      end
      self
    end

    def wait
      @session.loop { @complete }
    end
    
  private
  
    def archive
      @archive ||= File.basename(@destination) + '.tgz'
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
        yield
      else
        Dir.chdir(File.dirname(@repository)) do
          system("tar czf #{local_archive} #{File.basename(@repository)}")
        end

        @sftp.upload(local_archive, remote_archive) do
          command = "cd #{File.dirname(@destination)} && tar xzf #{remote_archive} && mv #{File.basename(@repository)} #{File.basename(@destination)}; rm #{remote_archive}"
          run_asynchronously(command) do
            yield
          end
        end
      end
    end
    
    def destination_exist?
      @sftp.lstat!(@destination)
      true
    rescue Net::SFTP::StatusException
      false
    end
    
    # Yields upon command completion.
    def run_asynchronously(command)
      @session.open_channel do |channel|
        channel.exec(command) do |ch, success|
          unless success
            @on_error.call("could not open channel")
            yield
          else
            channel.on_request "exit-status" do |ch, data|
              @on_error.call("command failed: #{command}") unless data.read_long.zero?
              yield
            end
          end
        end
      end
    end
  end
end
