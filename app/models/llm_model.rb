# A model in the deployment's LLM catalog — pi's model id plus operator
# curation (enabled, label, ordering). Synced from pi by
# Agent::ModelCatalogSync; the `key` is passed to pi verbatim as --model.
# Deployment-level (see LlmProvider).
class LlmModel < ApplicationRecord
  validates :key, presence: true, uniqueness: { scope: :llm_provider_id }
  validates :label, presence: true

  belongs_to :llm_provider

  scope :enabled, -> { where(enabled: true) }
  scope :ordered, -> { order(:position, :key) }
end
