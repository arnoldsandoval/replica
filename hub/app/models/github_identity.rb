# == Schema Information
#
# Table name: github_identities
# Database name: primary
#
#  id         :integer          not null, primary key
#  avatar_url :string
#  login      :string           not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  github_id  :bigint           not null
#
# Indexes
#
#  index_github_identities_on_github_id  (github_id) UNIQUE
#
# Check Constraints
#
#  github_identities_login        (length(trim(login)) > 0)
#  github_identities_positive_id  (github_id > 0)
#
# Retains a mention recipient before or after their first Hub sign-in.
class GithubIdentity < ApplicationRecord
  has_many :comment_mentions, dependent: :restrict_with_exception
  has_many :notifications, foreign_key: :recipient_id, inverse_of: :recipient, dependent: :restrict_with_exception
  belongs_to :user, foreign_key: :github_id, primary_key: :github_id, optional: true

  validates :github_id, numericality: { only_integer: true, greater_than: 0 }
  validates :login, presence: true
  attr_readonly :github_id

  # Upserts a verified GitHub profile by immutable ID inside the comment transaction.
  def self.record!(profile)
    identity = create_or_find_by!(github_id: profile.fetch(:github_id)) do |recipient|
      recipient.login = profile.fetch(:login)
      recipient.avatar_url = profile[:avatar_url]
    end
    identity.update! login: profile.fetch(:login), avatar_url: profile[:avatar_url]
    identity
  end
end
