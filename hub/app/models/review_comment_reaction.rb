# == Schema Information
#
# Table name: review_comment_reactions
# Database name: primary
#
#  id                :integer          not null, primary key
#  content           :string           not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  review_comment_id :integer          not null
#  user_id           :integer          not null
#
# Indexes
#
#  index_review_comment_reactions_on_identity           (review_comment_id,user_id,content) UNIQUE
#  index_review_comment_reactions_on_review_comment_id  (review_comment_id)
#  index_review_comment_reactions_on_user_id            (user_id)
#
# Foreign Keys
#
#  review_comment_id  (review_comment_id => review_comments.id) ON DELETE => cascade
#  user_id            (user_id => users.id) ON DELETE => restrict
#
# Check Constraints
#
#  review_comment_reactions_content  (content IN ('+1', '-1', 'laugh', 'hooray', 'confused', 'heart', 'rocket', 'eyes'))
#
# Stores one reviewer's reaction to one live review message.
class ReviewCommentReaction < ApplicationRecord
  CONTENTS = %w[+1 -1 laugh hooray confused heart rocket eyes].freeze

  belongs_to :review_comment
  belongs_to :user

  validates :content, inclusion: { in: CONTENTS }
  validates :content, uniqueness: { scope: %i[review_comment_id user_id] }
  validate :comment_is_live
  validate :identity_is_unchanged, on: :update
  before_destroy :remove_notification

  private

  # Withdraws the activity record even when a reaction is removed outside the thread action.
  def remove_notification
    Notification.remove_for_reaction!(self)
  end

  # Keeps reactions off comments whose text has been deleted.
  def comment_is_live
    return if review_comment.nil? || review_comment.deleted_at.nil?

    errors.add(:review_comment, "must contain a live comment")
  end

  # Keeps one reaction attached to its original reviewer and message.
  def identity_is_unchanged
    %i[review_comment_id user_id content].each do |attribute|
      errors.add(attribute, "cannot change") if public_send("will_save_change_to_#{attribute}?")
    end
  end
end
