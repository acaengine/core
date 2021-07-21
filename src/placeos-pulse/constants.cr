
module PlaceOS::Pulse
  APP_NAME = "PlaceOS Pulse"
  VERSION  = {{ `shards version "#{__DIR__}"`.chomp.stringify.downcase }}

  PLACEOS_PORTAL_URI = ENV["PLACEOS_PORTAL_URI"]
  PORTAL_API_KEY = ENV["PORTAL_API_KEY"]
  INSTANCE_SECRET_KEY = ENV["INSTANCE_SECRET_KEY"] # or generate
end