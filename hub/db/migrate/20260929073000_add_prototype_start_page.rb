class AddPrototypeStartPage < ActiveRecord::Migration[8.1]
  def change
    add_column :prototypes, :start_page, :string, limit: 2048
    add_check_constraint :prototypes,
      "start_page IS NULL OR (length(CAST(start_page AS BLOB)) BETWEEN 1 AND 2048 " \
        "AND substr(start_page, 1, 1) = '/' AND substr(start_page, 1, 2) != '//')",
      name: "prototypes_start_page"

    add_column :share_preview_grants, :return_path, :string, limit: 2048, default: "/", null: false
    add_check_constraint :share_preview_grants,
      "length(CAST(return_path AS BLOB)) BETWEEN 1 AND 2048 AND substr(return_path, 1, 1) = '/'",
      name: "share_preview_grants_return_path"
  end
end
