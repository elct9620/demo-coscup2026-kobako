class Endpoint < ApplicationRecord
  enum :status, { active: "active" }, validate: true

  # Reverse of GenerationRequest#belongs_to :endpoint — lets the index show the
  # natural-language requirement that produced each live endpoint.
  has_one :generation_request, dependent: :nullify

  before_validation :generate_slug, on: :create

  validates :slug, presence: true, uniqueness: true
  validates :script, presence: true
  validates :status, presence: true

  private

  def generate_slug
    self.slug = SecureRandom.urlsafe_base64(8) if slug.blank?
  end
end
