RubyLLM.configure do |config|
  llm = Rails.application.config.llm

  # 指向本地 LMStudio（OpenAI 相容端點）。api_key 為佔位值，LMStudio 不驗證。
  config.openai_api_base = llm.api_base
  config.openai_api_key  = llm.api_key
  config.openai_use_system_role = true

  # Use the new association-based acts_as API (recommended)
  config.use_new_acts_as = true
end
