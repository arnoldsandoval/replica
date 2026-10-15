class CreateSecurityAuditEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :hub_admin, :boolean, null: false, default: false

    create_table :security_audit_events do |t|
      t.string :action, null: false
      t.string :outcome, null: false
      t.datetime :occurred_at, null: false
      t.references :repository, foreign_key: { on_delete: :nullify }
      t.boolean :repository_scoped, null: false, default: false
      t.references :user, foreign_key: { on_delete: :nullify }
      t.string :ip_address
      t.json :context, null: false, default: {}
      t.index :occurred_at
      t.index [ :repository_id, :occurred_at, :id ]
    end
    add_check_constraint :security_audit_events,
      "outcome IN ('succeeded', 'denied', 'failed')", name: "security_audit_events_outcome"
    add_check_constraint :security_audit_events,
      "json_valid(context) AND json_type(context) = 'object'", name: "security_audit_events_context"
    add_check_constraint :security_audit_events,
      "repository_scoped = 1 OR repository_id IS NULL", name: "security_audit_events_repository_scope"

    create_table :hub_admin_enrollments do |t|
      t.string :proof_digest, null: false
      t.string :oauth_state_digest
      t.datetime :expires_at, null: false
      t.datetime :consumed_at
      t.timestamps
      t.index :proof_digest, unique: true
      t.index :expires_at
    end
  end
end
