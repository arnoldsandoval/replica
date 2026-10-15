class AddLearningRemovalToReviewComments < ActiveRecord::Migration[8.1]
  def change
    # When Hub queues the removal of a deleted comment's text from its learning store again, in case
    # the first job was never queued or kept failing. Removal clears it.
    add_column :review_comments, :learning_removal_due_at, :datetime
    add_index :review_comments, :learning_removal_due_at, where: "learning_removal_due_at IS NOT NULL"
  end
end
