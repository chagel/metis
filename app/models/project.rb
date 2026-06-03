class Project < ApplicationRecord
  NAME_MAX = 80

  validates :name, presence: true,
                    uniqueness: { scope: :team_id },
                    length: { maximum: NAME_MAX },
                    format: { without: /[\r\n]/, message: "can't contain line breaks" }

  belongs_to :team
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :updated_by, class_name: "User", optional: true

  has_many :conversations, dependent: :nullify

  scope :recent, -> { order(updated_at: :desc) }
end
