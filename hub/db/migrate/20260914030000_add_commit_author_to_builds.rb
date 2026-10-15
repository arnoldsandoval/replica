class AddCommitAuthorToBuilds < ActiveRecord::Migration[8.1]
  def change
    change_table :builds, bulk: true do |table|
      table.string :commit_author_name
      table.bigint :commit_author_github_id
      table.string :commit_author_login
      table.string :commit_author_avatar_url, limit: 2048
    end

    add_check_constraint \
      :builds,
      "commit_author_name IS NULL OR length(trim(commit_author_name)) BETWEEN 1 AND 255",
      name: "builds_commit_author_name"
    add_check_constraint \
      :builds,
      "commit_author_name IS NULL AND commit_author_github_id IS NULL AND " \
        "commit_author_login IS NULL AND commit_author_avatar_url IS NULL OR " \
        "commit_author_name IS NOT NULL AND commit_author_github_id IS NULL AND " \
        "commit_author_login IS NULL AND commit_author_avatar_url IS NULL OR " \
        "commit_author_name IS NOT NULL AND commit_author_github_id > 0 AND " \
        "length(trim(commit_author_login)) BETWEEN 1 AND 255 AND " \
        "(commit_author_avatar_url IS NULL OR " \
        "length(CAST(commit_author_avatar_url AS BLOB)) BETWEEN 1 AND 2048)",
      name: "builds_commit_author_identity"
  end
end
