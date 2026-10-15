class TrackLocalBranchHeadActivity < ActiveRecord::Migration[8.1]
  def change
    add_column :prototypes, :local_head_observed_at, :datetime
  end
end
