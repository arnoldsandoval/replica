class AddCommitAuthorRequestToBuilds < ActiveRecord::Migration[8.1]
  def change
    add_column :builds, :commit_author_requested_at, :datetime
  end
end
