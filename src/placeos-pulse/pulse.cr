require "placeos-models"
require "ulid"
require "hashcash"
require "rethinkdb-orm"
require "http/client"
require "tasker"
require "sodium"
require "uri"

module PlaceOS::Pulse
  # getter instance_id : String
  # getter secret_key : Sodium::Sign::SecretKey

  class Register # envelope, letter head, 
    include JSON::Serializable

    getter instance_id : String # ulid!
    getter message : JSON::Any  # make it a string...?
    getter signature : String   # use sodium datatype here

    def initialize(
      @instance_id : String,
      @message : Message,
      @signature : String
    )
    end
  end


  # private getter task : Tasker::Repeat(HTTP::Client::Response)

  # def initialize(
  #   @instance_id : String,
  #   secret_key : String?,
  #   heartbeat_interval : Time::Span = 1.day
  # )
  #   @secret_key = Sodium::Sign::SecretKey.new(secret_key.hexbytes)
  #   @task = Tasker.every(heartbeat_interval) { heartbeat }
  # end

  def heartbeat
    Message.new(@instance_id, @secret_key).send
  end

  def finalize
    @task.cancel
  end

  def register
    # from portal pls fix
    # how a signature is created
    message = {
      "systems_qty" => 12,
      "levels_qty"  => 30,
    }.to_json

    sec_key_string = "b18e1d0045995ec3d010c387ccfeb984d783af8fbb0f40fa7db126d889f6dadd77f48b59caeda77751ed138b0ec667ff50f8768c25d48309a8f386a2bad187fb"
    pub_key_string = "77f48b59caeda77751ed138b0ec667ff50f8768c25d48309a8f386a2bad187fb"
    key = Sodium::Sign::SecretKey.new(sec_key_string.hexbytes, pub_key_string.hexbytes)
    sig = key.sign_detached(message).hexstring

    json = {
      "instance_id" => "01EZZRAS54NA896VS67XEVF0G8",
      "message"     => JSON.parse(message),
      "signature"   => sig,
    }.to_json
    instance_request = PlaceOS::Portal::Api::InstanceRequest.from_json(json)
  end

  class Message
    include JSON::Serializable
    getter instance_id : String
    getter contents : Heartbeat # revise type, make generic
    getter signature : String
    getter portal_uri : URI
  
    def initialize(
      @instance_id : String,
      secret_key : Sodium::Sign::SecretKey,
      @contents = Heartbeat.new,
      @portal_uri : URI = URI.parse "http://placeos.run"
    )
      @signature = (secret_key.sign_detached @contents.to_json).hexstring
    end
  
    def payload
      {instance_id: @instance_id, contents: @contents, signature: @signature}.to_json
    end
  
    def send(custom_uri_path : String? = "") # e.g. /setup
      headers = {"X-API-KEY" => PlaceOS::Pulse::PORTAL_API_KEY}
      
      HTTP::Client.post "#{PlaceOS::Pulse::PLACEOS_PORTAL_URI}/instances/#{@instance_id}#{custom_uri_path}", body: payload.to_json
    end
  end
end



require "./heartbeat.cr"
