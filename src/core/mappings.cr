require "action-controller/logger"
require "driver/storage"
require "driver/subscriptions"
require "models/control_system"
require "models/module"

require "./module_manager"

module PlaceOS
  # TODO resource manager for removing module mappings on module deletes
  class Core::Mappings < Core::Resource(Model::ControlSystem)
    private getter? startup : Bool = true

    def initialize(
      @logger : TaggedLogger = TaggedLogger.new(Logger.new(STDOUT)),
      @startup : Bool = true
    )
      super(@logger)
    end

    def process_resource(event) : Resource::Result
      Mappings.update_mapping(event[:resource], startup?, logger)
    rescue e
      message = e.try(&.message) || ""
      logger.tag_error("while updating mapping for system", error: message)
      errors << {name: event[:resource].name.as(String), reason: message}

      Resource::Result::Error
    end

    def self.update_mapping(
      system : Model::ControlSystem,
      startup : Bool = false,
      logger : TaggedLogger = TaggedLogger.new(Logger.new(STDOUT))
    ) : Resource::Result
      # NOTE the module's custom name is not used for the key
      system_id = system.id.as(String)
      module_ids = system.modules.as(Array(String))

      destroyed = system.destroyed?

      # Always load mappings during startup
      relevant_node = startup || ModuleManager.instance.discovery.own_node?(system_id)
      needs_update = startup || destroyed || system.modules_changed?

      if relevant_node && needs_update
        storage = Driver::Storage.new(system_id, "system")
        storage.clear

        if !destroyed
          # Construct a hash of module_id to redis key
          keys = {} of String => String?
          module_ids.each_with_index do |id, index|
            # Extract module name
            model = Model::Module.find!(id)
            name = model.custom_name || model.name

            # Indexes start from 1
            storage["#{name}/#{index + 1}"] = id
          end

          # Notify subscribers of a system module ordering change
          Driver::Storage.redis_pool.publish(Driver::Subscriptions::SYSTEM_ORDER_UPDATE, system_id)
        end

        logger.tag_info("#{destroyed ? "deleted" : "created"} indirect module mappings", system_id: system_id)

        Resource::Result::Success
      else
        Resource::Result::Skipped
      end
    end

    def start
      super
      @startup = false
      self
    end
  end
end
