require "uuid"
require "../lib/action-controller/spec/curl_context"

# Application config
require "../src/config"
require "../src/placeos-core"
require "../src/placeos-core/*"

require "placeos-models/spec/generator"

require "spec"

SPEC_DRIVER = "drivers/place/private_helper.cr"
CORE_URL    = ENV["CORE_URL"]? || "http://core:3000"

# To reduce the run-time of the very setup heavy specs.
# - Use teardown if you need to clear a temporary repository
# - Use setup(fresh: true) if you require a clean working directory
TEMP_DIR = get_temp

def get_temp
  "#{Dir.tempdir}/core-spec-#{UUID.random.to_s.split('-').first}"
end

def teardown(temp_dir = TEMP_DIR)
  `rm -rf #{temp_dir}`
end

def clear_tables
  PlaceOS::Model::ControlSystem.clear
  PlaceOS::Model::Repository.clear
  PlaceOS::Model::Driver.clear
  PlaceOS::Model::Module.clear
  PlaceOS::Model::Edge.clear
end

def discovery_mock
  DiscoveryMock.new("core", uri: CORE_URL)
end

def module_manager_mock
  discovery = discovery_mock
  clustering = MockClustering.new(uri: CORE_URL, discovery: discovery)
  PlaceOS::Core::ModuleManager.new(CORE_URL, discovery: discovery, clustering: clustering)
end

Spec.after_each { GC.collect }

macro around_suite(block)
  Spec.before_suite do
    {{ block }}.call
  end
  Spec.after_suite do
    {{ block }}.call
  end
end

around_suite ->{
  clear_tables
  HoundDog::Service.clear_namespace
}

Spec.before_suite do
  # Set the working directory before specs
  set_temporary_working_directory
  Log.builder.bind("*", backend: PlaceOS::Core::LOG_STDOUT, level: Log::Severity::Trace)
  Log.builder.bind("http.client", backend: PlaceOS::Core::LOG_STDOUT, level: Log::Severity::Warn)
  Log.builder.bind("clustering", backend: PlaceOS::Core::LOG_STDOUT, level: Log::Severity::Error)
  Log.builder.bind("hound_dog.*", backend: PlaceOS::Core::LOG_STDOUT, level: Log::Severity::Error)
end

Spec.after_suite do
  PlaceOS::Core::ResourceManager.instance.stop
  Log.builder.bind("*", backend: PlaceOS::Core::LOG_STDOUT, level: Log::Severity::Error)
  puts "\n> Terminating stray driver processes"
  `pkill -f ".*core-spec.*"` rescue nil
  teardown
end

# Set up a temporary directory
def set_temporary_working_directory(fresh : Bool = false) : String
  temp_dir = fresh ? get_temp : TEMP_DIR
  PlaceOS::Compiler.bin_dir = "#{temp_dir}/bin"
  PlaceOS::Compiler.drivers_dir = "#{temp_dir}/repositories/private-drivers"
  PlaceOS::Compiler.repository_dir = "#{temp_dir}/repositories"

  Dir.mkdir_p(PlaceOS::Compiler.bin_dir)
  Dir.mkdir_p(PlaceOS::Compiler.drivers_dir)
  Dir.mkdir_p(PlaceOS::Compiler.repository_dir)

  temp_dir
end

# Create models for a test
def setup(fresh : Bool = false, temporary : Bool = true, role : PlaceOS::Model::Driver::Role? = nil)
  # Set up a temporary directory
  temp_dir = set_temporary_working_directory(fresh)

  # Repository metadata
  repository_uri = "https://github.com/placeos/private-drivers"
  repository_name = "Private Drivers"
  repository_folder_name = "private-drivers"

  # Driver metadata
  driver_file_name = "drivers/place/private_helper.cr"
  driver_module_name = "PrivateHelper"
  driver_name = "spec_helper"
  driver_commit = "HEAD"
  driver_role = role || PlaceOS::Model::Driver::Role::Logic

  existing_repo = PlaceOS::Model::Repository.where(uri: repository_uri).first?
  existing_driver = existing_repo.try(&.drivers.first?)
  existing_module = existing_driver.try(&.modules.first?)

  needs_control_system = driver_role.logic? && !existing_module.try(&.control_system)
  right_driver_role = role ? !!existing_driver.try(&.role.== role) : true

  if existing_repo && existing_driver && existing_module && !needs_control_system && right_driver_role
    repository, driver, mod = existing_repo, existing_driver, existing_module
  else
    clear_tables

    repository = PlaceOS::Model::Generator.repository(type: PlaceOS::Model::Repository::Type::Driver)
    repository.uri = repository_uri
    repository.name = repository_name
    repository.folder_name = repository_folder_name
    repository.save!

    driver = PlaceOS::Model::Driver.new(
      name: driver_name,
      role: driver_role,
      commit: driver_commit,
      module_name: driver_module_name,
      file_name: driver_file_name,
    )

    driver.repository = repository
    driver.save!

    mod = PlaceOS::Model::Generator.module(driver: driver)
    mod.running = true
    mod.save!

    control_system = if needs_control_system
                       mod.control_system = PlaceOS::Model::Generator.control_system.save! unless mod.control_system
                       mod.control_system.as(PlaceOS::Model::ControlSystem)
                     else
                       PlaceOS::Model::Generator.control_system
                     end

    control_system.modules = [mod.id.as(String)]
    control_system.save
  end

  {temp_dir, repository, driver, mod}
end

def create_resources(fresh : Bool = false, process : Bool = true)
  # Prepare models, set working dir
  _, repository, driver, mod = setup(fresh)

  # Clone, compile
  resource_manager = PlaceOS::Core::ResourceManager.new(testing: true)
  resource_manager.start { } if process

  {repository, driver, mod, resource_manager}
end

class DiscoveryMock < HoundDog::Discovery
  DOES_NOT_MAP = "<does-not-map>"

  def own_node?(key : String) : Bool
    key != DOES_NOT_MAP
  end

  def etcd_nodes
    [@service_events.node].map &->HoundDog::Discovery.to_hash_value(HoundDog::Service::Node)
  end
end

class MockClustering < Clustering
  def start(&stabilize : Array(HoundDog::Service::Node) ->)
    @stabilize = stabilize
    stabilize.call([discovery.node])
  end

  def stop
  end
end
