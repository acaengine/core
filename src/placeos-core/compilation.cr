require "placeos-compiler/compiler"
require "placeos-compiler/helper"
require "placeos-models/driver"
require "placeos-models/repository"
require "placeos-resource"

require "placeos-build/client"

require "./cloning"
require "./module_manager"

module PlaceOS
  class Core::Compilation < Resource(Model::Driver)
    private getter? startup : Bool = true
    private getter module_manager : ModuleManager
    private getter compiler_lock = Mutex.new

    getter binary_dir : String

    def initialize(
      @startup : Bool = true,
      @binary_dir : String = Path["./bin/drivers"].expand.to_s,
      @module_manager : ModuleManager = ModuleManager.instance
    )
      Dir.mkdir_p binary_dir
      buffer_size = System.cpu_count.to_i
      super(buffer_size)
    end

    def self.fetch_driver(
      driver : Model::Driver,
      username : String? = nil,
      password : String? = nil,
      request_id : String? = nil
    ) : String?
      result = Build::Client.client(BUILD_URI) do |client|
        client.compile(
          file: driver.file_name,
          url: driver.repository.uri,
          commit: driver.commit,
          username: username,
          password: password,
          request_id: request_id
        ) do |key, driver_io|
          File.open(File.join(binary_dir, key), mode: "w+", perm: File::Permissions.new(0o744)) do |file_io|
            IO.copy driver_io, file_io
          end
        end
      end
      result.path if result.is_a? Build::Compilation::Success
    end

    def process_resource(action : Resource::Action, resource driver : Model::Driver) : Resource::Result
      case action
      in .created?, .updated?
        success, output = compiler_lock.synchronize { Compilation.compile_driver(driver, startup?, module_manager) }

        unless success
          if driver.compilation_output.nil? || driver.recompile_commit? || driver.commit_changed?
            driver.update_fields(compilation_output: output)
          end
          raise Resource::ProcessingError.new(driver.name, output)
        end

        driver.update_fields(compilation_output: nil) unless driver.compilation_output.nil?
        Resource::Result::Success
      in .deleted?
        Result::Skipped
      end
    rescue exception
      raise Resource::ProcessingError.new(driver.name, "#{exception} #{exception.message}", cause: exception)
    end

    # ameba:disable Metrics/CyclomaticComplexity
    def self.compile_driver(
      driver : Model::Driver,
      startup : Bool = false,
      module_manager : ModuleManager = ModuleManager.instance
    ) : Tuple(Bool, String)
      driver_id = driver.id.as(String)
      repository = driver.repository!

      force_recompile = driver.recompile_commit?
      commit = force_recompile.nil? ? driver.commit : force_recompile

      ::Log.with_context do
        Log.context.set(
          driver_id: driver_id,
          name: driver.name,
          file_name: driver.file_name,
          repository_name: repository.folder_name,
          commit: commit,
        )

        if !force_recompile && !driver.commit_changed? && Compiler::Helper.compiled?(driver.file_name, commit, driver_id)
          Log.info { "commit unchanged and driver already compiled" }
          module_manager.reload_modules(driver)
          return {true, ""}
        end

        Log.info { "force recompiling driver" } if force_recompile
      end

      # If the commit is `head` then the driver must be recompiled at the latest version
      if Compilation.pull?(commit)
        begin
          Cloning.clone_and_install(repository)
        rescue e
          return {false, "failed to pull and install #{repository.folder_name}: #{e.try &.message}"}
        end
      end

      result = Compiler.build_driver(
        driver.file_name,
        repository.folder_name,
        commit,
        id: driver_id
      )

      unless result.success?
        Log.error { {message: "failed to compile driver", output: result.output, repository_name: repository.folder_name} }
        return {false, "failed to compile #{driver.name} from #{repository.folder_name}: #{result.output}"}
      end

      Log.info { {
        message:         "compiled driver",
        name:            driver.name,
        executable:      result.name,
        repository_name: repository.folder_name,
        output:          result.output,
      } }

      # (Re)load modules onto the newly compiled driver
      stale_path = module_manager.reload_modules(driver)

      # Remove the stale driver if there was one
      remove_stale_driver(driver_id: driver_id,
        path: stale_path,
      )

      # Bump the commit on the driver post-compilation and module loading
      if (Compilation.pull?(commit) || force_recompile) && (startup || module_manager.discovery.own_node?(driver_id))
        update_driver_commit(driver: driver, commit: result.commit, startup: startup)
      end

      {result.success?, ""}
    end

    # Remove the stale driver binary if there was one
    #
    def self.remove_stale_driver(path : Path?, driver_id : String)
      return unless path
      Log.info { {message: "removing stale driver binary", driver_id: driver_id, path: path.to_s} }
      File.delete(path) if File.exists?(path)
    rescue
      Log.error { {message: "failed to remove stale binary", driver_id: driver_id, path: path.to_s} }
    end

    def self.update_driver_commit(driver : Model::Driver, commit : String, startup : Bool)
      if startup
        # There's a potential for multiple writers on startup, However this is an eventually consistent operation.
        Log.warn { {message: "updating commit on driver during startup", id: driver.id, name: driver.name, commit: commit} }
      end

      driver.update_fields(commit: commit)
      Log.info { {message: "updated commit on driver", id: driver.id, name: driver.name, commit: commit} }
    end

    protected def self.pull?(commit : String?)
      commit.try(&.upcase) == "HEAD"
    end

    def start
      super
      @startup = false
      self
    end
  end
end
