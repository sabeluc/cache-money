ActiveRecord::Schema.define(:version => 4) do
  create_table "stories", :force => true do |t|
    t.string "title", "subtitle"
    t.string  "type"
    t.boolean "published"
  end

  create_table "characters", :force => true do |t|
    t.integer "story_id"
    t.string "name"
  end
  
  create_table "fables", :force => true do |t|
    t.string "author"
    t.integer "num_pages"
  end
  
  create_table "tales", :force => true do |t|
    t.string "title"
    t.integer "height"
  end
end
