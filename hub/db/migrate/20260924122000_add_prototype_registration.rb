class AddPrototypeRegistration < ActiveRecord::Migration[8.1]
  def change
    change_table :prototypes do |table|
      table.string :name
      table.string :description, limit: 500
      table.datetime :registered_at
    end

    add_check_constraint :prototypes,
      "name IS NULL OR length(trim(name)) BETWEEN 1 AND 255",
      name: "prototypes_name"
    add_check_constraint :prototypes,
      "description IS NULL OR length(trim(description)) BETWEEN 1 AND 500",
      name: "prototypes_description"
    add_check_constraint :prototypes,
      "registered_at IS NULL OR name IS NOT NULL",
      name: "prototypes_registration"
  end
end
