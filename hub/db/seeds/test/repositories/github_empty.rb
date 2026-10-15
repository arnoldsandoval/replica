# An installed GitHub repository before its first prototype is published.
github_app_configurations.create_installed :github

users.create :octocat, unique_by: :github_id

repositories.create \
  :github_empty,
  unique_by: :github_id,
  github_id: 2_002,
  name_with_owner: "github/empty"
