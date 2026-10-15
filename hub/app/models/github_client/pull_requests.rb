# Calls GitHub pull request APIs for workflow installation.
class GithubClient::PullRequests
  # Uses the shared GitHub API transport.
  def initialize(transport)
    @transport = transport
  end

  # Lists open pull requests for one exact source and target branch.
  def list_open(repository, head:, base:, token:)
    query = {
      state: "open",
      head: "#{repository.owner_login}:#{head}",
      base: base
    }.to_query
    entries = transport.request \
      :get,
      "/repos/#{repository.github_path}/pulls?#{query}",
      token: token
    if !entries.is_a?(Array)
      raise GithubClient::InvalidResponse, "GitHub returned an invalid pull request list"
    end

    entries
  end

  # Opens one pull request from the prepared workflow branch.
  def create(repository, head:, base:, title:, body:, token:)
    transport.request \
      :post,
      "/repos/#{repository.github_path}/pulls",
      token: token,
      body: { head: head, base: base, title: title, body: body },
      expected_status: [ 201 ]
  end

  private

  attr_reader :transport
end
