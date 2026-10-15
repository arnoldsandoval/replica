# == Schema Information
#
# Table name: branch_banner_dismissals
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
#  index_branch_banner_dismissals_on_prototype_id              (prototype_id)
#  index_branch_banner_dismissals_on_user_id                   (user_id)
#  index_branch_banner_dismissals_on_user_id_and_prototype_id  (user_id,prototype_id) UNIQUE
#
# Foreign Keys
#
#  prototype_id  (prototype_id => prototypes.id) ON DELETE => cascade
#  user_id       (user_id => users.id) ON DELETE => cascade
#
# Remembers branches whose registration banner one person declined.
class BranchBannerDismissal < ApplicationRecord
  belongs_to :user
  belongs_to :prototype

  class << self
    # Keeps repeated or concurrent dismissals attached to the signed-in person.
    def record!(user:, prototype:)
      find_or_create_by!(user:, prototype:)
    end
  end
end
