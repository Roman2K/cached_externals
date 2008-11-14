require 'test/unit'
require 'mocha'

require 'cached_externals'

class CachedExternalsTest < Test::Unit::TestCase
  def test_external_modules
    # Inexistent config/externals.yml
    File.stubs(:read).with("config/externals.yml").raises(Errno::ENOENT)
    assert_equal({}, CachedExternals.external_modules)
    
    # String as keys
    File.stubs(:read).with("config/externals.yml").returns <<-EOS
      vendor/foo:
        type: git
        :revision: deadbeef
    EOS
    begin
      CachedExternals.external_modules
    rescue ArgumentError => error
    end
    assert(error, "did not raise ArgumentError")
    assert_match(/found \["type"\] under vendor\/foo/, error.message)
    
    # Valid
    File.stubs(:read).with("config/externals.yml").returns <<-EOS
      vendor/foo:
        :type: git
        :revision: deadbeef
    EOS
    assert_equal({'vendor/foo' => {:type => 'git', :revision => 'deadbeef'}}, CachedExternals.external_modules)
    
    # ERB evaluation
    File.stubs(:read).with("config/externals.yml").returns("contents")
    ERB.stubs(:new).with("contents").returns(stub)
    ERB.new("contents").stubs(:result).with(TOPLEVEL_BINDING).returns("entry:\n  :property: value")
    
    assert_equal({'entry' => {:property => 'value'}}, CachedExternals.external_modules)
  end
end

require 'pathname'

class CachedExternals::IntegrationTest < Test::Unit::TestCase
  STORE   = Pathname(__FILE__).expand_path.dirname.join('store')
  LOCAL   = STORE.join('local')
  REMOTE  = STORE.join('remote')
  
  CAPFILE_TAIL = <<-RUBY
    require 'capistrano/recipes/deploy/scm/git'
    
    Capistrano::Deploy::SCM::Git.class_eval do
      alias_method :old_initialize, :initialize
      def initialize(*args, &block)
        old_initialize(*args, &block)
        @configuration[:repository] = File.expand_path(@configuration[:repository]) if File.directory?(@configuration[:repository])
      end
      
      alias_method :old_query_revision, :query_revision
      def query_revision(revision)
        if File.directory?(repository)
          Dir.chdir(repository) { yield(scm('ls-remote', '.', revision)).split[0] }
        else
          old_query_revision(revision)
        end
      end
    end
    
    logger.level = Capistrano::Logger::IMPORTANT
  RUBY
  
  def setup
    run!("cd #{STORE.parent} && rm -rf store && tar xf store.tar")    
    LOCAL.join('config', 'deploy.rb').open('a') { |f| f << CAPFILE_TAIL }
    @previous_directory = Pathname.pwd
    Dir.chdir(STORE)
  end
  
  def teardown
    Dir.chdir(@previous_directory)
    run!("cd #{STORE.parent} && rm -rf store")
  end
  
  def test_local_externals_setup
    run!("cd #{LOCAL} && cap local externals:setup")
    directory = LOCAL.parent.join('shared', 'externals', 'vendor', 'plugins')
    
    assert_local_directory_library_checked_out(directory, :symlink)
    assert_version_controlled_library_checked_out(directory)
  end
  
  def test_remote_externals_setup
    run!("cd #{LOCAL} && cap deploy")
    directory = REMOTE.join('shared', 'externals', 'vendor', 'plugins')
    
    assert !REMOTE.parent.join('shared').exist?
    assert_local_directory_library_checked_out(directory)
    assert_version_controlled_library_checked_out(directory)
  end
  
private
  
  def run!(command)
    system(command) or raise "command failed: `#{command}`"
  end
  
  def assert_version_controlled_library_checked_out(directory, *args)
    assert_checkout_successful(directory.join('version-controlled'), 'd1e75b54e446f1a2098472289ec443a5c7647c40', *args)
  end
  
  def assert_local_directory_library_checked_out(directory, *args)
    assert_checkout_successful(directory.join('local-directory'), '947432ba438b24ec6ab90ce9b160e521', *args)
  end
  
  def assert_checkout_successful(directory, revision, symlink=false)
    assert directory.directory?
    assert_equal [revision], directory.children.map { |p| p.basename.to_s }
    if symlink
      assert directory.children.first.symlink?
    else
      assert directory.children.first.directory?
    end
    assert directory.children.first.join('contents.txt').file?
  end
end
