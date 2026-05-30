class CreateGenerationRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :generation_requests do |t|
      t.text :requirement, null: false
      t.string :status, null: false, default: "pending"
      t.text :error_message
      # Nullable — populated only when generation succeeds.
      t.references :endpoint, null: true, foreign_key: true
      # Nullable — wired in when EndpointBuilderAgent uses a persisted Chat (#13).
      t.references :chat, null: true, foreign_key: true

      t.timestamps
    end
  end
end
