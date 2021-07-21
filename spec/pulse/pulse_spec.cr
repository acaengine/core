# require "./helper"

require "../../src/placeos-pulse/*"
require "spec"

PlaceOS::Core::PROD = true
# require "webmock"

# describe PlaceOS::Core::Pulse, focus: true do
#   it "should run tests" do
#     true.should eq true
#     puts "it worked"
#   end
# end

# alias Pulse = PlaceOS::Core::Pulse

describe PlaceOS::Pulse do
  # it ".new" do
  #   pulse = PlaceOS::Pulse.new("01EY4PBEN5F999VQKP55V4C3WD", "b18e1d0045995ec3d010c387ccfeb984d783af8fbb0f40fa7db126d889f6dadd77f48b59caeda77751ed138b0ec667ff50f8768c25d48309a8f386a2bad187fb")
  #   pulse.instance_id.should eq "01EY4PBEN5F999VQKP55V4C3WD"
  #   # pulse.secret_key.should eq "b18e1d0045995ec3d010c387ccfeb984d783af8fbb0f40fa7db126d889f6dadd77f48b59caeda77751ed138b0ec667ff50f8768c25d48309a8f386a2bad187fb"
  # end

  # it ".heartbeat" do
  #   WebMock.stub(:post, "http://placeos.run/instances/01EY4PBEN5F999VQKP55V4C3WD")
  #     .to_return(status: 201, body: "")

  #   pulse = PlaceOS::Core::Pulse.new("01EY4PBEN5F999VQKP55V4C3WD", "b18e1d0045995ec3d010c387ccfeb984d783af8fbb0f40fa7db126d889f6dadd77f48b59caeda77751ed138b0ec667ff50f8768c25d48309a8f386a2bad187fb")
  #   heartbeat = pulse.heartbeat
  #   heartbeat.should be_a HTTP::Client::Response
  #   heartbeat.status_code.should eq 201
  # end

  describe PlaceOS::Pulse::Message do
    it ".new" do
      secret = Sodium::Sign::SecretKey.new("b18e1d0045995ec3d010c387ccfeb984d783af8fbb0f40fa7db126d889f6dadd77f48b59caeda77751ed138b0ec667ff50f8768c25d48309a8f386a2bad187fb".hexbytes)
      message = PlaceOS::Pulse::Message.new("01EY4PBEN5F999VQKP55V4C3WD", secret)
      message.instance_id.should eq "01EY4PBEN5F999VQKP55V4C3WD"
      message.portal_uri.should eq URI.parse "http://placeos.run"
      message.signature.should eq "249117ed2ce8a5da8eaa7b3e95a87f219ff9126fd51e93d199c6783e9ef8b5816d4bc5798ad68983ad48a72829bc779b2293442af8f7f429fa761c64a5d58f09"

      secret.public_key.verify_detached(message.contents.to_json, message.signature.hexbytes).should be_nil
    end

    it ".payload" do
      secret = Sodium::Sign::SecretKey.new("b18e1d0045995ec3d010c387ccfeb984d783af8fbb0f40fa7db126d889f6dadd77f48b59caeda77751ed138b0ec667ff50f8768c25d48309a8f386a2bad187fb".hexbytes)
      message = PlaceOS::Pulse::Message.new("01EY4PBEN5F999VQKP55V4C3WD", secret)
      message.payload.should eq "{\"instance_id\":\"01EY4PBEN5F999VQKP55V4C3WD\",\"contents\":{\"drivers_qty\":0,\"zones_qty\":0,\"users_qty\":0,\"production\":true,\"desks\":[]},\"signature\":\"249117ed2ce8a5da8eaa7b3e95a87f219ff9126fd51e93d199c6783e9ef8b5816d4bc5798ad68983ad48a72829bc779b2293442af8f7f429fa761c64a5d58f09\"}"
    end

    # it ".send" do
    #   secret = Sodium::Sign::SecretKey.new("b18e1d0045995ec3d010c387ccfeb984d783af8fbb0f40fa7db126d889f6dadd77f48b59caeda77751ed138b0ec667ff50f8768c25d48309a8f386a2bad187fb".hexbytes)
    #   WebMock.stub(:post, "http://placeos.run/instances/01EY4PBEN5F999VQKP55V4C3WD")
    #     .to_return(status: 201, body: "")

    #   # heartbeat = Pulse::Heartbeat.new
    #   # Pulse::Heartbeat.new
    #   message = Message.new("01EY4PBEN5F999VQKP55V4C3WD", secret)
    #   response = message.send
    #   response.should be_a HTTP::Client::Response
    #   response.status_code.should eq 201
    # end
  end
end
