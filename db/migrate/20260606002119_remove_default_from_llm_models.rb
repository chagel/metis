class RemoveDefaultFromLlmModels < ActiveRecord::Migration[8.1]
  def change
    remove_index :llm_models, :is_default, unique: true, where: "is_default"
    remove_column :llm_models, :is_default, :boolean, null: false, default: false
  end
end
