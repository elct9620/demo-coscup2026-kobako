class Endpoint < ApplicationRecord
  enum :status, { active: "active" }, validate: true

  before_validation :generate_slug, on: :create

  validates :slug, presence: true, uniqueness: true
  validates :script, presence: true
  validates :status, presence: true

  private

  def generate_slug
    self.slug = SecureRandom.urlsafe_base64(8) if slug.blank?
  end
end
