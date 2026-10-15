class AddCustomAnalyticsDestinations < ActiveRecord::Migration[8.1]
  def up
    add_column :analytics_destinations, :name, :string
    add_column :analytics_destinations, :custom_config, :text
    add_column :analytics_destinations, :revision, :integer, null: false, default: 1
    add_column :analytics_deliveries, :destination_revision, :integer, null: false, default: 1

    remove_index :analytics_destinations, name: "index_analytics_destinations_on_repository_id_and_provider"
    add_index :analytics_destinations, [ :repository_id, :provider ], unique: true,
      where: "provider != 'custom'", name: "index_analytics_destinations_on_builtin_provider"
    add_index :analytics_destinations, "repository_id, lower(name)", unique: true,
      where: "provider = 'custom'", name: "index_analytics_destinations_on_custom_name"
    add_check_constraint :analytics_destinations, "revision > 0", name: "analytics_destination_revision"
    add_check_constraint :analytics_deliveries, "destination_revision > 0",
      name: "analytics_delivery_destination_revision"

    remove_check_constraint :analytics_destinations, name: "analytics_destination_provider"
    add_check_constraint :analytics_destinations,
      "provider IN ('segment', 'mixpanel', 'custom')", name: "analytics_destination_provider"
    remove_check_constraint :analytics_destinations, name: "analytics_destination_region"
    add_check_constraint :analytics_destinations,
      "(provider = 'segment' AND region IN ('us', 'eu')) OR " \
        "(provider = 'mixpanel' AND region IN ('us', 'eu', 'in')) OR " \
        "(provider = 'custom' AND region = 'custom')",
      name: "analytics_destination_region"
  end

  def down
    remove_check_constraint :analytics_destinations, name: "analytics_destination_region"
    add_check_constraint :analytics_destinations,
      "(provider = 'segment' AND region IN ('us', 'eu')) OR " \
        "(provider = 'mixpanel' AND region IN ('us', 'eu', 'in'))",
      name: "analytics_destination_region"
    remove_check_constraint :analytics_destinations, name: "analytics_destination_provider"
    add_check_constraint :analytics_destinations,
      "provider IN ('segment', 'mixpanel')", name: "analytics_destination_provider"
    remove_check_constraint :analytics_deliveries, name: "analytics_delivery_destination_revision"
    remove_check_constraint :analytics_destinations, name: "analytics_destination_revision"

    remove_index :analytics_destinations, name: "index_analytics_destinations_on_custom_name"
    remove_index :analytics_destinations, name: "index_analytics_destinations_on_builtin_provider"
    add_index :analytics_destinations, [ :repository_id, :provider ], unique: true

    remove_column :analytics_deliveries, :destination_revision
    remove_column :analytics_destinations, :revision
    remove_column :analytics_destinations, :custom_config
    remove_column :analytics_destinations, :name
  end
end
