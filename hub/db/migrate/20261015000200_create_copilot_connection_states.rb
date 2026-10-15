# A disconnected connection leaves this counter intact to cancel earlier token checks.
class CreateCopilotConnectionStates < ActiveRecord::Migration[8.1]
  def change
    create_table :copilot_connection_states do |t|
      t.integer :singleton_key, null: false, default: 1
      t.bigint :generation, null: false, default: 0
      t.timestamps
      t.index :singleton_key, unique: true
    end
    add_check_constraint \
      :copilot_connection_states, "singleton_key = 1", name: "copilot_connection_states_singleton"
    add_check_constraint \
      :copilot_connection_states, "generation >= 0", name: "copilot_connection_states_generation"
  end
end
