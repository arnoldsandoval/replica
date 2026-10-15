class CreateSessionRevocations < ActiveRecord::Migration[8.1]
  def change
    create_table :session_revocations do |t|
      t.integer :singleton_key, null: false, default: 1
      t.bigint :generation, null: false, default: 0
      t.datetime :ended_at
      t.timestamps
      t.index :singleton_key, unique: true
    end
    add_check_constraint :session_revocations, "singleton_key = 1",
      name: "session_revocations_singleton"
    add_check_constraint :session_revocations, "generation >= 0",
      name: "session_revocations_generation"
  end
end
