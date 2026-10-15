class AddCommitAuthorCheckToBuilds < ActiveRecord::Migration[8.1]
  def change
    add_column :builds, :commit_author_checked_at, :datetime
  end
end
