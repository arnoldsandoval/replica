class StrengthenCommitAuthorIdentity < ActiveRecord::Migration[8.1]
  OLD_EXPRESSION = "commit_author_name IS NULL AND commit_author_github_id IS NULL AND " \
    "commit_author_login IS NULL AND commit_author_avatar_url IS NULL OR " \
    "commit_author_name IS NOT NULL AND commit_author_github_id IS NULL AND " \
    "commit_author_login IS NULL AND commit_author_avatar_url IS NULL OR " \
    "commit_author_name IS NOT NULL AND commit_author_github_id > 0 AND " \
    "length(trim(commit_author_login)) BETWEEN 1 AND 255 AND " \
    "(commit_author_avatar_url IS NULL OR " \
    "length(CAST(commit_author_avatar_url AS BLOB)) BETWEEN 1 AND 2048)"
  NEW_EXPRESSION = "CASE " \
    "WHEN commit_author_name IS NULL THEN " \
    "commit_author_github_id IS NULL AND commit_author_login IS NULL AND commit_author_avatar_url IS NULL " \
    "WHEN commit_author_github_id IS NULL THEN " \
    "commit_author_login IS NULL AND commit_author_avatar_url IS NULL " \
    "ELSE commit_author_github_id > 0 AND commit_author_login IS NOT NULL AND " \
    "length(trim(commit_author_login)) BETWEEN 1 AND 255 AND " \
    "(commit_author_avatar_url IS NULL OR " \
    "length(CAST(commit_author_avatar_url AS BLOB)) BETWEEN 1 AND 2048) END"

  def change
    remove_check_constraint \
      :builds,
      OLD_EXPRESSION,
      name: "builds_commit_author_identity"
    add_check_constraint \
      :builds,
      NEW_EXPRESSION,
      name: "builds_commit_author_identity"
  end
end
