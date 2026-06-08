class AddPreferredRuntimeToUsers < ActiveRecord::Migration[8.1]
  def change
    # A user's default runtime for new chats, mirroring preferred_model.
    # Optional — blank means "use the deployment default". Gated to the
    # deployment's enabled runtimes at chat creation.
    add_column :users, :preferred_runtime, :string
  end
end
