# Detects later head observations even when a branch returns to the same Build.
class AddHeadObservationRevisionToPrototypes < ActiveRecord::Migration[8.1]
  def change
    add_column :prototypes, :head_observation_revision, :bigint, default: 0, null: false
  end
end
