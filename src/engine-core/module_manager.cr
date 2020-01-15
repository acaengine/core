require "action-controller"
require "engine-driver/protocol/management"
require "engine-drivers/compiler"
require "engine-drivers/helper"
require "engine-models"
require "habitat"
require "hound-dog"
require "rethinkdb-orm"

module ACAEngine
  class Core::ModuleManager
    include Drivers::Helper

    getter discovery : HoundDog::Discovery
    getter logger : ActionController::Logger::TaggedLogger = settings.logger

    Habitat.create do
      setting ip : String = ENV["CORE_HOST"]? || "localhost"
      setting port : Int32 = (ENV["CORE_PORT"]? || 3000).to_i
      setting logger : ActionController::Logger::TaggedLogger = ActionController::Logger::TaggedLogger.new(Logger.new(STDOUT))
    end

    # # Ready-state logic sketch
    # increment_string = ->(var : String) { (var.to_i + 1).to_s }
    #
    # value = "0" unless (value = client.get(key))
    #
    # # Attempt to increment the nodes in the cluster state
    # # This will require a slight change to the etcd library (regarding return type)
    # value, success = client.compare_and_swap(key, value, increment_string.call(value)) # result => {String, Bool}
    #
    # until success
    #     value, success = client.compare_and_swap(key, value, increment_string.call(value))
    # end
    #
    # # Set up a watch feed on the cluster state.
    # # Once the cluster state for ready nodes is equal to the cluster, continue.
    # # The watch feed occurs separately,
    # # - Once the ready state is reached, it continues operations.
    # # - If the state is inconsistent, it triggers the above block (stabilize, then increment)
    # # - Flow is blocked by the watch feed

    # From environment
    @@instance : ModuleManager?

    # Class to be used as a singleton
    def self.instance : ModuleManager
      (@@instance ||= ModuleManager.new(ip: settings.ip, port: settings.port)).as(ModuleManager)
    end

    # Mapping from module_id to protocol manager
    @module_proc_managers = {} of String => Driver::Protocol::Management
    # Mapping from driver path to protocol manager
    @driver_proc_managers = {} of String => Driver::Protocol::Management

    # Once registered, run through all the modules, consistent hashing to determine what modules need to be loaded
    # Start the driver processes as required.
    # Launch the modules on those processes etc
    # Once all the modules are running. Mark in etcd that load is complete.
    def initialize(
      ip : String,
      port : Int32,
      discovery : HoundDog::Discovery? = HoundDog::Discovery.new(service: "core")
    )
      @discovery = discovery || HoundDog::Discovery.new(service: "core", ip: ip, port: port)
    end

    def watch_modules
      Model::Module.changes.each do |change|
        mod = change[:value]
        mod_id = mod.id.as(String)
        if change[:event] == RethinkORM::Changefeed::Event::Deleted
          remove_module(mod) if manager_by_module_id(mod_id)
        else
          if mod.running_changed?
            # Running state of the module changed
            mod.running ? start_module(mod) : stop_module(mod)
          else
            # Load/Reload the module
            load_module(mod)
          end
        end
      end
    end

    # The number of drivers loaded on current node
    def running_drivers
      @driver_proc_managers.size
    end

    # The number of module processes on current node
    def running_modules
      @module_proc_managers.size
    end

    def manager_by_module_id(mod_id : String) : Driver::Protocol::Management?
      @module_proc_managers[mod_id]?
    end

    def manager_by_driver_path(path : String) : Driver::Protocol::Management?
      @driver_proc_managers[path]?
    end

    def start
      logger.debug("loading modules")

      # Self-register
      discovery.register { balance_modules }

      # Listen for incoming module changes
      spawn(same_thread: true) { watch_modules }

      balance_modules

      logger.tag_info("loaded modules", drivers: running_drivers, modules: running_modules)
      Fiber.yield

      self
    end

    def start_module(mod : Model::Module)
      cs = mod.control_system.as(Model::ControlSystem)

      # Start format
      payload = {
        ip:   mod.ip,
        port: mod.port,
        # TODO: remove '|| false' after Module has updated defaults
        udp:            mod.udp || false,
        tls:            mod.tls || false,
        makebreak:      mod.makebreak,
        role:           mod.role,
        settings:       mod.merge_settings,
        control_system: {
          id:   cs.id,
          name: cs.name,
          # TODO: remove '|| ""' after ControlSystem has updated defaults
          email:    cs.email || "",
          features: cs.features || "",
          capacity: cs.capacity,
          bookable: cs.bookable,
        },
      }.to_json

      # NOTE: The settings object needs to be unescaped
      # OPTIMIZE: Might be better if the driver parses the setttings as a seperate JSON chunk
      payload = payload.gsub(/"settings":"{(.*)}",/) do |m1|
        m1.gsub(/"{(.*)}"/) do |m2|
          m2.strip('"')
        end
      end

      mod_id = mod.id.as(String)
      proc_manager = manager_by_module_id(mod_id)

      raise ModuleError.new("No protocol manager for #{mod_id}") unless proc_manager

      logger.tag_info("starting module protocol manager", module_id: mod_id, driver: mod.driver.try &.name)
      proc_manager.start(mod_id, payload)
    end

    # Stop module on node
    def stop_module(mod : Model::Module)
      mod_id = mod.id.as(String)
      manager_by_module_id(mod_id).try &.stop(mod_id)
    end

    # Stop and remove the module from node
    def remove_module(mod : Model::Module)
      mod_id = mod.id.as(String)
      manager_by_module_id(mod_id).try &.stop(mod_id)
      @module_proc_managers.delete(mod_id)
    end

    def balance_modules
      Model::Module.all.each &->load_module(Model::Module)
    end

    # Used in `on_exec` for locating the remote module
    def which_core?(hash_id : String)
      node = discovery.find!(hash_id)
      own_node = node[:ip] == @discovery.ip && node[:port] == @discovery.port
      {own_node, URI.new(host: node[:ip], port: node[:port])}
    end

    def on_exec(request : Request, response_cb : Proc(Request, Nil))
      # Protocol.instance.expect_response(@module_id, @reply_id, "exec", request, raw: true)
      remote_module_id = request.id
      raw_execute_json = request.payload.not_nil!

      this_node, core_uri = which_core?(remote_module_id)

      if this_node
        if manager = @module_proc_managers[remote_module_id]?
          # responds with a JSON string
          request.payload = manager.execute(remote_module_id, raw_execute_json)
        else
          raise "could not locate module #{remote_module_id}. It may not be running."
        end
      else
        # build request
        core_uri.path = "/api/core/v1/command/#{remote_module_id}/execute"
        response = HTTP::Client.post(
          core_uri,
          headers: HTTP::Headers{"X-Request-ID" => ""},
          body: raw_execute_json
        )

        case response.status_code
        when 200
          # exec was successful, json string returned
          request.payload = response.body
        when 203
          # exec sent to module and it raised an error
          info = NamedTuple(message: String, backtrace: Array(String)?).from_json(response.body)
          request.payload = info[:message]
          request.backtrace = info[:backtrace]
          request.error = "RequestFailed"
        else
          # some other failure 3
          request.payload = "unexpected response code #{response.status_code}"
          request.error = "UnexpectedFailure"
        end
      end

      response_cb.call(request)
    rescue error
      request.set_error(error)
      response_cb.call(request)
    end

    def save_setting(module_id : String, setting_name : String, setting_value : JSON::Any)
      # TODO::
    end

    alias Request = ACAEngine::Driver::Protocol::Request

    # Load the module if current node is responsible
    def load_module(mod : Model::Module)
      mod_id = mod.id.as(String)
      if discovery.own_node?(mod_id)
        driver = mod.driver.as(Model::Driver)
        driver_name = driver.name.as(String)
        driver_file_name = driver.file_name.as(String)
        driver_commit = driver.commit.as(String)

        # Check if the module is on the current node
        unless (driver_path = ACAEngine::Drivers::Compiler.is_built?(driver_file_name, driver_commit))
          logger.tag_error("driver does not exist", driver_name: driver_name, driver_commit: driver_commit, module_id: mod_id)
          return
        end

        if manager_by_module_id(mod_id)
          # Module already loaded
          logger.tag_info("module already loaded", module_id: mod_id, driver_name: driver_name, driver_commit: driver_commit)
        elsif (existing_driver_manager = manager_by_driver_path(driver_path))
          # Use the existing driver protocol manager
          @module_proc_managers[mod_id] = existing_driver_manager
        else
          # Create a new protocol manager
          proc_manager = Driver::Protocol::Management.new(driver_path, logger)

          # Hook up the callbacks
          proc_manager.on_exec = ->(request : Request, response_cb : Proc(Request, Nil)) {
            on_exec(request, response_cb); nil
          }
          proc_manager.on_setting = ->(module_id : String, setting_name : String, setting_value : JSON::Any) {
            save_setting(module_id, setting_name, setting_value); nil
          }

          @driver_proc_managers[driver_path] = proc_manager
          @module_proc_managers[mod_id] = proc_manager
        end

        start_module(mod)
      elsif manager_by_module_id(mod_id)
        # Not on node, but protocol manager exists
        logger.tag_info("stopping module protocol manager", module_id: mod_id)
        remove_module(mod)
      end
    end
  end
end
