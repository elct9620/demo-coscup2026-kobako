# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 專案概述

COSCUP 2026 的 Demo：**動態唯讀 API 端點生成器**。操作者以自然語言描述報表需求，本地 LLM（LMStudio）在 WASM 沙盒（Kobako）中自動生成並驗證 read-only 的 mruby 腳本，無需改程式碼或重新部署即可上線為動態 API 端點。

兩份文件是權威來源，動手前必讀：

- **[`SPEC.md`](SPEC.md)** — 目標狀態與邊界（行為、不變式），維持實作中立。
- **[`docs/architecture.md`](docs/architecture.md)** — **約束實作**：技術棧、目錄對應、關鍵模式。其 `Patterns` 段是設計的不變式來源。

實作前先讀這兩份；它們的描述比既有程式碼更具權威性（目前多數功能尚未實作）。

## 常用指令

```bash
bin/setup            # 安裝相依、準備資料庫（首次）
bin/dev              # foreman 啟動 web(Puma) + css(tailwind watch)；開發主要入口
bin/rails db:prepare # 建立/遷移資料庫

# 測試（Minitest）
bin/rails test                          # 全部
bin/rails test test/models/chat_test.rb # 單一檔案
bin/rails test test/models/chat_test.rb:42  # 單一測試（指定行號）

# 靜態檢查與安全（與 CI 同一組，見 config/ci.rb）
bin/rubocop          # 風格（rubocop-rails-omakase）
bin/brakeman         # 安全靜態分析
bin/bundler-audit    # 相依套件弱點
bin/ci               # 一次跑完整 CI 流程（setup→rubocop→audit→brakeman→test→seed）
```

LLM 生成功能需要本機 **LMStudio 在 `http://localhost:1234/v1` 運行**，並以 `LLM_MODEL` 指定已載入的模型（預設 `google/gemma-4-26b-a4b`）。可用 `LLM_API_BASE` / `LLM_API_KEY` / `LLM_MODEL` 覆寫（見 `config/llm.yml`）。

## 架構大圖

設計取向為 **Rails 原生 + DCI（Data, Context, Interaction）**，刻意避開帶 ports/adapters 的重量級 Clean Architecture。細節見 `docs/architecture.md`，要點：

- **Data** = 薄 ActiveRecord models（`Endpoint`、`Event`、`Metric` + RubyLLM 的 `Chat`/`Message`/`ToolCall`/`Model`）。業務編排不放這裡。
- **Context** = 一個 use case 一個 PORO 編排物件，落在 `app/contexts/`：`EndpointGeneration`（生成迴圈）、`EndpointReplay`（對外重放）。
- **Interaction** = 綁進沙盒的唯讀查詢角色（= SPEC 的 **Service**），落在 `app/sandbox/`：`EventQuery`、`MetricQuery`。

兩條主流程共用同一個 `ReadOnlySandbox` builder：

1. **生成**：`EndpointGenerationJob` → `EndpointGeneration` → `EndpointBuilderAgent`（RubyLLM）寫腳本 → 以 `inspect_query` 探索資料、`submit_endpoint` 提交最終腳本 → 結構化錯誤回饋給 LLM 重試 → `submit_endpoint` 通過後讀 `submit_tool.captured_script` 建立 `Endpoint`。
2. **重放**：`GET /e/:slug` → `DynamicEndpointsController` → `EndpointReplay` → 以全新沙盒重放上線腳本。

### 三個核心不變式（修改時別繞過）

- **兩層唯讀防禦**：(1) 能力邊界——沙盒只綁 `EventQuery`/`MetricQuery`，無寫入入口；(2) SQL 邊界——查詢走 `reading` 連線，以 SQLite `mode=ro` 開檔，寫入在連線層即被拒。兩層獨立成立。
- **驗證即上線（shared execution path）**：`submit_endpoint`（驗證）與 `EndpointReplay`（服務）共用同一個 `ReadOnlySandbox`——同一條執行路徑；只有 `submit_endpoint` 捕獲的腳本會被持久化，保證「驗證時所見＝上線後結果」。
- **error-as-feedback 自我驗證迴圈（雙工具）**：以 RubyLLM Agent + `inspect_query`（探索、不驗 envelope）+ `submit_endpoint`（驗 envelope + 捕獲）的原生 tool-calling 迴圈實現；兩工具結構化錯誤作為 tool result 餵回，`before_tool_call` 對兩工具計數封頂達成有限迭代。

## 關鍵慣例與注意事項

- **沿用函式庫原生慣例，別造包裝層**：RubyLLM（`app/agents`、`app/tools`、`app/prompts` + `acts_as_*` models）與 Kobako（`Sandbox#define.bind` 綁 Service、`#run`/`#eval`、`Handle` 代理、MessagePack wire codec）直接以原生 API 使用。先讀函式庫文件再決定要不要包裝。
- **LLM 設定走 `config_for(:llm)`**：環境相關的結構化設定置於 `config/llm.yml`（ERB 取 ENV），於 `config/application.rb` 載入為 `config.llm`，再於 `config/initializers/ruby_llm.rb` 套用。不要把 `ENV.fetch` 塞回 `config.x`。
- **RubyLLM 用新版 acts_as**：initializer 已設 `config.use_new_acts_as = true`；勿退回 legacy `acts_as` API（會有 deprecation 警告）。
- **資料庫**：dev/test 為單一 SQLite；多資料庫（`cache`/`queue`/`cable` 各自獨立 SQLite）只在 production。`solid_*` 在 dev 走 memory/async。
- **`bin/dev` 的 tailwind watch 用 `tailwindcss:watch[always]`**（`--watch=always`），使其在無 TTY 環境也常駐，避免 foreman「一退全收」。
- **資產管線**：Propshaft + importmap（無 Node/package.json）；Tailwind v4 經 standalone CLI 編譯到 `app/assets/builds/`，layout 以 Rails 8.1 的 `stylesheet_link_tag :app` 自動含括。

## Design Context

前端設計工作由 impeccable skill 管理，策略基準寫在根目錄 **[`PRODUCT.md`](PRODUCT.md)**，動手做前端前先讀它。要點：

- **Register**：`product`（工具型 app UI），主要展示情境是 **COSCUP 舞台投影 Demo**。
- **核心印象**：流暢、有點魔法 → 視覺語言走「亮色編輯風 + 精準動態」。
- **設計原則**：過程即主角（即時串流的 Generation Log 是主舞台）、Show don't tell（三個唯讀不變式要被看見）、投影幕優先（高對比大字級）、克制的精準（動態服務理解、無炫技）、工程的真誠。
- **Anti-references**：通用預設 Tailwind（目前 indigo/灰階/白底細邊框就是反例）、AI 生成感、賣相 SaaS landing、過度炫技動畫。

視覺系統（色彩、字體、components）寫在 `DESIGN.md`（建立後）；視覺決策以 DESIGN.md 為準，策略／語氣決策以 PRODUCT.md 為準。
