# == Schema Information
#
# Table name: prototype_introductions
# Database name: primary
#
#  id           :integer          not null, primary key
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  prototype_id :integer          not null
#  user_id      :integer          not null
#
# Indexes
#
#  index_prototype_introductions_on_prototype_id              (prototype_id)
#  index_prototype_introductions_on_user_id                   (user_id)
#  index_prototype_introductions_on_user_id_and_prototype_id  (user_id,prototype_id) UNIQUE
#
# Foreign Keys
#
#  prototype_id  (prototype_id => prototypes.id) ON DELETE => cascade
#  user_id       (user_id => users.id) ON DELETE => cascade
#
# Remembers which prototypes a person has already opened.
class PrototypeIntroduction < ApplicationRecord
  belongs_to :user
  belongs_to :prototype

  class << self
    # Records the first opening once, including concurrent requests.
    def record!(user:, prototype:)
      create_or_find_by!(user:, prototype:)
    end
  end
end
