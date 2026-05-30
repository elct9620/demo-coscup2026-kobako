class Event < ApplicationRecord
  validates :name, presence: true
  validates :occurred_at, presence: true

  scope :recent_days, ->(days) { where(occurred_at: days.days.ago..) }
  scope :by_name, ->(name) { where(name: name) }
  scope :occurring_on, ->(date) { where(occurred_at: date.all_day) }
end
