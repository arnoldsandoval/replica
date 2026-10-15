# Rejects origin requests that did not come through the configured Front Door.
class AzureFrontDoorVerification
  HEADER = "HTTP_X_AZURE_FDID"
  HEALTH_PATH = "/up"
  NOT_FOUND = [ 404, { "content-type" => "text/plain", "content-length" => "0" }, [] ].freeze

  # Leaves deployments unrestricted until they configure a Front Door ID.
  def initialize(app, front_door_id: ENV["REPLICA_AZURE_FRONT_DOOR_ID"])
    @app = app
    @front_door_id = front_door_id.to_s.downcase
  end

  # Rejects requests that bypass or come from another Front Door profile.
  def call(environment)
    return @app.call(environment) if @front_door_id.blank?
    return @app.call(environment) if environment["PATH_INFO"] == HEALTH_PATH

    submitted = environment[HEADER].to_s.downcase
    return NOT_FOUND if submitted.bytesize != @front_door_id.bytesize
    return NOT_FOUND if !ActiveSupport::SecurityUtils.secure_compare(submitted, @front_door_id)

    @app.call(environment)
  end
end
