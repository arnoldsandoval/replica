# == Schema Information
#
# Table name: sessions
# Database name: primary
#
#  id                  :integer          not null, primary key
#  fresh_authorized_at :datetime
#  ip_address          :string
#  user_agent          :string
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  user_id             :integer          not null
#
# Indexes
#
#  index_sessions_on_user_id  (user_id)
#
# Foreign Keys
#
#  user_id  (user_id => users.id) ON DELETE => cascade
#
class Session < ApplicationRecord
  belongs_to :user

  validates :user, presence: true
end
