class CreateEndpoints < ActiveRecord::Migration[8.1]
  def change
    create_table :endpoints do |t|
      t.string :slug, null: false
      t.text :script, null: false
      t.string :status, null: false, default: "active"

      t.timestamps
    end

    add_index :endpoints, :slug, unique: true
  end
end
