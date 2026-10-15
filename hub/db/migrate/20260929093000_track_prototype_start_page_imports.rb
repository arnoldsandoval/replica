class TrackPrototypeStartPageImports < ActiveRecord::Migration[8.1]
  def up
    add_column :prototypes, :start_page_set_at, :datetime
    add_column :prototypes, :start_page_import_error, :string
    add_column :builds, :start_page_checked_at, :datetime
    execute <<~SQL
      UPDATE prototypes SET start_page_set_at = CURRENT_TIMESTAMP
      WHERE start_page IS NOT NULL OR registered_at IS NOT NULL
    SQL
  end

  def down
    remove_column :builds, :start_page_checked_at
    remove_column :prototypes, :start_page_import_error
    remove_column :prototypes, :start_page_set_at
  end
end
