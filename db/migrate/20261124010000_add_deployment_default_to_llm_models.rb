class AddDeploymentDefaultToLlmModels < ActiveRecord::Migration[8.1]
  def change
    add_column :llm_models, :deployment_default, :boolean, default: false, null: false
    add_index :llm_models, :deployment_default, unique: true, where: "deployment_default"
  end
end
