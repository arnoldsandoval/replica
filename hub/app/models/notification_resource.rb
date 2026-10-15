# == Schema Information
#
# Table name: notification_resources
# Database name: primary
#
#  id              :integer          not null, primary key
#  resource_type   :string           not null
#  role            :string           not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  notification_id :integer          not null
#  resource_id     :integer          not null
#
# Indexes
#
#  index_notification_resources_on_identity         (notification_id,resource_type,resource_id,role) UNIQUE
#  index_notification_resources_on_notification_id  (notification_id)
#  index_notification_resources_on_resource         (resource_type,resource_id)
#
# Foreign Keys
#
#  notification_id  (notification_id => notifications.id) ON DELETE => cascade
#
# Check Constraints
#
#  notification_resources_role  (role IN ('primary', 'context'))
#
# Associates a notification with its message and contextual prototype.
class NotificationResource < ApplicationRecord
  belongs_to :notification
  belongs_to :resource, polymorphic: true

  validates :role, inclusion: { in: %w[primary context] }
  validates :resource_id, uniqueness: { scope: %i[notification_id resource_type role] }
end
