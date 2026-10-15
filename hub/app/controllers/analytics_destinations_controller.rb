# Requires a fresh repository-admin permission for every analytics mutation.
class AnalyticsDestinationsController < ApplicationController
  include FreshAuthorizationRequired
  before_action :authorize_repository
  before_action :authorize_sensitive_action
  before_action -> { enforce_security_rate_limit(:analytics_destinations) }
  rescue_from GithubClient::Error, with: -> { head :service_unavailable }
  rescue_from ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActionController::ParameterMissing,
    with: :invalid_configuration
  rescue_from Analytics::CustomConfiguration::Invalid, Analytics::CustomEndpoint::Invalid,
    with: :invalid_custom_configuration

  # @route POST /repositories/:repository_github_id/analytics/destinations (repository_analytics_destinations)
  def create
    @destination = @repository.analytics_destinations.new
    configure_destination
  end

  # @route PATCH /repositories/:repository_github_id/analytics/destinations/:id (repository_analytics_destination)
  # @route PUT /repositories/:repository_github_id/analytics/destinations/:id (repository_analytics_destination)
  def update
    @destination = @repository.analytics_destinations.find(params[:id])
    if params[:operation].in?(%w[pause resume])
      @destination.update!(enabled: params[:operation] == "resume")
      redirect_to repository_analytics_path(@repository.route_id), status: :see_other
    else
      configure_destination
    end
  end

  # @route DELETE /repositories/:repository_github_id/analytics/destinations/:id (repository_analytics_destination)
  def destroy
    @repository.analytics_destinations.find(params[:id]).destroy!
    redirect_to \
      repository_analytics_path(@repository.route_id),
      notice: t("analytics.disconnected"),
      status: :see_other
  end

  private

  # GitHub repository administration remains necessary in addition to fresh identity.
  def authorize_sensitive_action
    # The isolated development demo has no GitHub identity to verify.
    return if LocalDevelopment.enabled? && @repository.local? && Current.user.local?

    require_fresh_authorization \
      purpose: "analytics_destination", return_to: repository_analytics_path(@repository.route_id)
  end

  def security_audit_action
    operation = { "create" => "create", "destroy" => "delete", "update" => "update" }[action_name]
    if action_name == "update" && params[:operation].in?(%w[pause resume])
      operation = params[:operation]
    end
    "analytics_destination.#{operation}"
  end

  # Direct URLs cannot bypass repository selection or current GitHub permission.
  def authorize_repository
    @repository = Repository.find_by_route_id!(params[:repository_github_id])
    allowed = @repository.authorization.authorized?(Current.user, minimum: :admin, fresh: true)
    head :not_found if !allowed
  end

  # Blank rotation fields keep existing secrets without ever returning them to the client.
  def configure_destination
    input = params.require(:destination).permit \
      :provider, :region, :history, :name, :endpoint, :template, :headers,
      :success_pointer, :success_value, :keep_pending,
      event_types: [],
      credentials: %i[write_key service_account_username service_account_secret project_id],
      secrets: %i[name value]
    if @destination.new_record? && !input[:history].in?(%w[new retained])
      return invalid_configuration
    end

    provider = input[:provider] || @destination.provider
    attributes = { provider:, event_types: input.fetch(:event_types, []).reject(&:blank?) }
    if provider == "custom"
      secrets = input.fetch(:secrets, [])
      secrets = secrets.values if secrets.is_a?(ActionController::Parameters)
      custom_input = input.permit(:endpoint, :template, :headers, :success_pointer, :success_value).to_h
      custom_input["secrets"] = secrets.map(&:to_h)
      previous = if @destination.persisted?
        Analytics::CustomConfiguration.new(@destination.custom_config, @destination.credentials)
      end
      Analytics::CustomConfiguration.from_input! \
        custom_input, previous:, existing_secrets: @destination.credentials || {}
      Analytics::CustomEndpoint.new(custom_input.fetch("endpoint")).public_ip!
      attributes.merge!(name: input[:name], custom_input:)
    else
      attributes.merge!(region: input[:region], credentials: input.fetch(:credentials, {}).to_h)
    end
    include_retained = @destination.new_record? && input[:history] == "retained"
    @destination.configure! \
      attributes, include_retained:, keep_pending: provider == "custom" && input[:keep_pending] == "1"
    redirect_to \
      repository_analytics_path(@repository.route_id),
      notice: t("analytics.configured_notice"),
      status: :see_other
  end

  # Reports validation without echoing submitted provider credentials.
  def invalid_configuration
    record_security_audit(outcome: "failed")
    custom_input = params[:destination].is_a?(ActionController::Parameters) &&
      params[:destination][:provider] == "custom"
    key = if @destination&.provider == "custom" || custom_input
      "analytics.invalid_custom_configuration"
    else
      "analytics.invalid_configuration"
    end
    redirect_to \
      repository_analytics_path(@repository.route_id),
      alert: t(key),
      status: :see_other
  end

  # Keeps URL settings, response data, and submitted credentials out of errors.
  def invalid_custom_configuration
    record_security_audit(outcome: "failed")
    redirect_to \
      repository_analytics_path(@repository.route_id),
      alert: t("analytics.invalid_custom_configuration"),
      status: :see_other
  end
end
