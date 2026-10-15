class CreateAnalyticsEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :prototypes, :first_published_at, :datetime

    reversible do |direction|
      direction.up { backfill_first_publications }
    end

    create_table :analytics_events do |table|
      table.references :repository, null: false, foreign_key: true
      table.string :uuid, null: false
      table.string :source_key, null: false
      table.string :name, null: false
      table.string :actor_id
      table.json :properties, null: false
      table.datetime :occurred_at, null: false
    end
    add_index :analytics_events, :uuid, unique: true
    add_index :analytics_events, :source_key, unique: true
    add_index :analytics_events, :occurred_at
    add_index :analytics_events, [ :id, :repository_id ], unique: true
    add_check_constraint :analytics_events,
      "name IN ('prototype_registered', 'prototype_first_published', 'build_published', " \
        "'review_comment_created', 'review_reply_added', 'review_thread_resolved', " \
        "'review_thread_reopened')", name: "analytics_events_name"
    add_check_constraint :analytics_events,
      "json_valid(properties) AND json_type(properties) = 'object'",
      name: "analytics_events_properties"
  end

  # Marks historical publications without creating historical events.
  def backfill_first_publications
    execute <<~SQL
      UPDATE prototypes SET first_published_at = (
        SELECT MIN(finished_at) FROM builds
        WHERE builds.prototype_id = prototypes.id AND builds.state = 'successful'
      )
    SQL
  end
end
