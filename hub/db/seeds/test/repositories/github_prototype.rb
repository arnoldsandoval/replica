# A typical GitHub repository with a reviewable prototype and two reviewers.
github_app_configurations.create_installed :github

users.create :octocat, unique_by: :github_id
users.create \
  :mona,
  unique_by: :github_id,
  github_id: 1_002,
  login: "mona",
  name: "Mona Lisa",
  avatar_url: "https://avatars.githubusercontent.com/u/1002"

repository = repositories.create \
  :github_prototype,
  unique_by: :github_id,
  github_id: 2_001,
  name_with_owner: "github/prototype"
prototype = prototypes.create(:welcome, repository: repository)
builds.create_successful(:welcome, prototype: prototype)
