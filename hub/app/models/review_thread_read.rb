# == Schema Information
#
# Table name: review_thread_reads
# Database name: primary
#
#  id                         :integer          not null, primary key
#  last_seen_activity_version :integer          not null
#  read_at                    :datetime         not null
#  created_at                 :datetime         not null
#  updated_at                 :datetime         not null
#  root_id                    :integer          not null
#  user_id                    :integer          not null
#
# Indexes
#
#  index_review_thread_reads_on_root_and_user  (root_id,user_id) UNIQUE
#  index_review_thread_reads_on_root_id        (root_id)
#  index_review_thread_reads_on_user_id        (user_id)
#
# Foreign Keys
#
#  root_id  (root_id => review_comments.id) ON DELETE => cascade
#  user_id  (user_id => users.id) ON DELETE => restrict
#
# Check Constraints
#
#  review_thread_reads_positive_version  (last_seen_activity_version > 0)
#
# Stores the latest thread activity one reviewer has seen.
class ReviewThreadRead < ApplicationRecord
  belongs_to :root, \
    class_name: "ReviewComment",
    inverse_of: :thread_reads
  belongs_to :user

  validates :last_seen_activity_version, \
    numericality: { only_integer: true, greater_than: 0 }
  validates :read_at, presence: true
  validates :root_id, uniqueness: { scope: :user_id }
  validate :root_is_root_comment
  validate :version_is_not_ahead
  validate :identity_is_unchanged, on: :update

  class << self
    # Records the latest activity this reviewer has seen without moving backward.
    def record!(root:, user:, activity_version:)
      read = find_or_initialize_by(root:, user:)
      seen_version = [ read.last_seen_activity_version.to_i, activity_version ].max
      read.update! \
        last_seen_activity_version: seen_version,
        read_at: Time.current
      read
    end
  end

  private

  # Requires read state to point to the root that owns thread activity.
  def root_is_root_comment
    return if root.nil? || root.root_comment?

    errors.add(:root, "must be a root comment")
  end

  # Prevents a reviewer from marking activity that the thread has not reached.
  def version_is_not_ahead
    return if root.nil? || last_seen_activity_version.nil?
    return if last_seen_activity_version <= root.activity_version

    errors.add(:last_seen_activity_version, "cannot be newer than the thread")
  end

  # Keeps read state attached to its original thread and reviewer.
  def identity_is_unchanged
    %i[root_id user_id].each do |attribute|
      errors.add(attribute, "cannot change") if public_send("will_save_change_to_#{attribute}?")
    end
  end
end
