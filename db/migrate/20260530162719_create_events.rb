class CreateEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :events do |t|
      t.datetime :occurred_at, null: false
      t.string :name, null: false
      t.json :properties, default: {}

      t.timestamps
    end

    add_index :events, :occurred_at
    add_index :events, :name
    add_index :events, [ :name, :occurred_at ]
  end
end
