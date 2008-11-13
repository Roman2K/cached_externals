require 'test/unit'
require 'mocha'

class CachedExternalsTest < Test::Unit::TestCase
  STORE = Pathname(__FILE__).dirname.join('store')
  LOCAL = STORE.join('local')
  
  CAPFILE_TAIL = <<-RUBY
    require 'capistrano/recipes/deploy/scm/git'
    Capistrano::Deploy::SCM::Git.class_eval do
      alias_method :old_query_revision, :query_revision
      def query_revision(revision)
        if File.directory?(repository)
          Dir.chdir(repository) { yield(scm('ls-remote', '.', revision)).split[0] }
        else
          old_query_revision(revision)
        end
      end
    end
  RUBY
  
  def setup
    run!("cd #{STORE.parent} && tar xf store.tar")
    @previous_directory = Pathname.pwd
    Dir.chdir(STORE)
    LOCAL.join('config', 'deploy.rb').open('a') { |f| f << CAPFILE_TAIL }
  end
  
  def teardown
    Dir.chdir(@previous_directory)
    run!("cd #{STORE.parent} && rm -rf store")
  end
  
  def test_local_externals_setup
    run!("cd #{LOCAL} && cap local externals:setup")
    checked_out_dependencies = LOCAL.parent.join('shared', 'externals', 'vendor', 'plugins')
    
    version_controlled = checked_out_dependencies.join('version-controlled')
    assert version_controlled.directory?
    assert_equal ['d1e75b54e446f1a2098472289ec443a5c7647c40'], version_controlled.children.map { |p| p.basename.to_s }
    assert version_controlled.children.first.directory?
    assert version_controlled.children.first.join('contents.txt').file?
    
    local_directory = checked_out_dependencies.join('local-directory')
    assert local_directory.directory?
    assert_equal ['947432ba438b24ec6ab90ce9b160e521'], local_directory.children.map { |p| p.basename.to_s }
    assert local_directory.children.first.symlink?
    assert local_directory.children.first.join('contents.txt').file?
  end
  
private
  
  def run!(command)
    system(command) or raise "command failed: `#{command}`"
  end
end
