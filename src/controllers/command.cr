require "./application"

module ACAEngine::Core::Api
  class Command < Application
    base "/api/core/v1/command/"

    getter module_manager = ModuleManager.instance

    # Executes a command against a module
    post "/:module_id/execute" do
      module_id = params["module_id"]
      protocol_manager = module_manager.manager_by_module_id(module_id)
      head :not_found unless protocol_manager

      body = request.body
      head :not_acceptable unless body

      # We don't parse the request here or parse the response, just proxy it.
      response.content_type = "application/json"
      response << protocol_manager.execute(module_id, body.gets_to_end)
    end

    # For now a one-to-one debug session to websocket should be fine as it's not
    # a common operation and limited to system administrators
    ws "/:module_id/debugger" do |socket|
      module_id = params["module_id"]
      protocol_manager = module_manager.manager_by_module_id(module_id)
      raise "module not loaded" unless protocol_manager

      # Forward debug messages to the websocket
      callback = ->(message : String) { socket.send(message); nil }
      protocol_manager.debug(module_id, &callback)

      # Stop debugging when the socket closes
      socket.on_close { protocol_manager.as(Driver::Protocol::Management).ignore(module_id, &callback) }
    end

    # In the long term we should move to a single websocket between API instances
    # and core instances, then we multiplex the debugging signals accross.
    ws "/debugger" do |_socket|
      raise "not implemented"
    end

    def initialize(@context, @action_name = :index, @__head_request__ = false)
      super(@context, @action_name, @__head_request__)
    end

    # Override initializer for specs
    def initialize(
      context : HTTP::Server::Context,
      action_name = :index,
      @module_manager : ModuleManager = ModuleManager.instance
    )
      super(context, action_name)
    end
  end
end
