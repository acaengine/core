require "secrets-env"

module PlaceOS::Core
  APP_NAME     = "core"
  API_VERSION  = "v1"
  VERSION      = {{ `shards version "#{__DIR__}"`.chomp.stringify.downcase }}
  BUILD_TIME   = {{ system("date -u").chomp.stringify }}
  BUILD_COMMIT = {{ env("PLACE_COMMIT") || "DEV" }}

  REPOS   = ENV["ENGINE_REPOS"]? || Path["./repositories"].expand.to_s
  DRIVERS = ENV["ENGINE_DRIVERS"]? || File.join(PlaceOS::Compiler.repository_dir, "drivers")

  ETCD_HOST = ENV["ETCD_HOST"]? || "localhost"
  ETCD_PORT = (ENV["ETCD_PORT"]? || 2379).to_i

  REDIS_URL = ENV["REDIS_URL"]? || "redis://localhost:6379"

  # `core` self-registers to etcd with this information.
  # In k8s we can grab the Pod information from the environment
  # https://kubernetes.io/docs/tasks/inject-data-application/environment-variable-expose-pod-information/#use-pod-fields-as-values-for-environment-variables
  CORE_HOST = ENV["CORE_HOST"]? || System.hostname
  CORE_PORT = (ENV["CORE_PORT"]? || "3000").to_i

  BUILD_HOST = ENV["PLACEOS_BUILD_HOST"]?.presence || "build"
  BUILD_PORT = ENV["PLACEOS_BUILD_PORT"]?.presence.try(&.to_i?) || 3000
  BUILD_URI  = URI.parse("http://#{BUILD_HOST}:#{BUILD_PORT}")

  PROD = ENV["SG_ENV"]?.try(&.downcase) == "production"

  class_getter? production : Bool = PROD
end
