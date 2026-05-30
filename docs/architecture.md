# Architecture Overview

本文件描述「動態唯讀 API 端點生成器」的實作架構。行為與邊界規格見 [`SPEC.md`](../SPEC.md)；本文件負責**約束實作**——技術棧、目錄對應與關鍵模式。

設計取向為 **Rails 原生 + DCI（Data, Context, Interaction）**，刻意避開帶 ports/adapters 的重量級分層。盡量使用 RubyLLM 與 Kobako 的原生慣例，不重造包裝層。

## DCI 三要素

| 要素 | 角色 | 在本專案 |
|------|------|----------|
| **Data** | 持久化的薄資料物件 | ActiveRecord models：`Endpoint`、`Event`、`Metric`，以及 RubyLLM 的 `Chat`/`Message`/`ToolCall`/`Model` |
| **Context** | 一個 use case 一個編排物件（PORO） | `EndpointGeneration`（生成迴圈）、`EndpointReplay`（對外重放） |
| **Interaction** | 物件在 Context 中扮演的角色 | 綁進沙盒的唯讀查詢角色 `EventQuery`、`MetricQuery` |

> DCI 的 **Interaction role** 即 SPEC 的 **Service**——綁進沙盒、供腳本呼叫的唯讀存取入口；本文件兩詞同義。

## Directory Mapping

```
app/
├── models/                         # Data（薄 ActiveRecord）
│   ├── endpoint.rb                 # 已驗證腳本 + slug + status（= 端點腳本／動態端點）
│   ├── event.rb                    # 網站分析事件：occurred_at, name, properties(JSON)
│   ├── metric.rb                   # 由 events 聚合的唯讀查詢
│   └── chat.rb / message.rb / tool_call.rb / model.rb   # ruby_llm:install 生成（生成歷史與可視化來源）
│
├── agents/
│   └── endpoint_builder_agent.rb   # RubyLLM::Agent：model→LMStudio、instructions、tools RunScriptTool
├── tools/
│   └── run_script_tool.rb          # RubyLLM::Tool：execute(script:) → 唯讀沙盒試跑，回傳 result/error
├── prompts/
│   └── endpoint_builder_agent/instructions.txt.erb   # Agent 系統提示（prompt 檔慣例）
│
├── contexts/                       # Context（DCI，use-case 編排 PORO）
│   ├── endpoint_generation.rb      # 跑 agent 自我驗證迴圈，成功則建立 Endpoint
│   └── endpoint_replay.rb          # 以全新唯讀沙盒重放已上線腳本
│
├── sandbox/
│   ├── read_only_sandbox.rb        # 共用 builder：Kobako::Sandbox + timeout/mem + 綁定唯讀 roles + 唯讀連線
│   ├── event_query.rb              # Interaction role：Events 唯讀查詢入口（Handle 鏈式組合）
│   └── metric_query.rb             # Interaction role：Metrics 唯讀查詢入口
│
├── controllers/
│   ├── endpoints_controller.rb         # 生成 UI（Hotwire/Turbo）
│   └── dynamic_endpoints_controller.rb # 對外重放服務（依 slug 找 Endpoint → EndpointReplay）
├── jobs/
│   └── endpoint_generation_job.rb      # SolidQueue：執行 EndpointGeneration context
└── views/ + Stimulus controllers + TailwindCSS v4
```

> RubyLLM 的 `ruby_llm:install` 會建立 `app/agents`、`app/tools`、`app/prompts` 目錄與 Chat/Message/ToolCall/Model 四個 model；沿用這些慣例，不另建抽象層。（`ruby_llm:install` 亦會生成 `app/schemas`，本 Demo 未用 structured output，故不納入上方目錄樹。）

## 生成與服務流程

**生成（自我驗證迴圈 = Agent 原生 tool-calling 迴圈）**

```
操作者自然語言需求
  → EndpointGenerationJob (SolidQueue)
    → EndpointGeneration context
      → EndpointBuilderAgent 寫 mruby 腳本
        → RunScriptTool.execute(script:)
          → ReadOnlySandbox 試跑（綁定 EventQuery/MetricQuery、唯讀連線）
          → 回傳 result 或結構化 error（error-as-feedback）
        ← Agent 據結果修正並重試（before_tool_call 計數封頂 = 有限迭代）
      → 試跑成功且回傳值可經 MessagePack 序列化（不可序列化值在 wire 邊界即視為 error，回饋 LLM）→ 建立 Endpoint(slug, script)
  → 每一輪 ToolCall/Message 經 broadcasts_to Turbo Stream 即時呈現
```

**對外服務（重放）**

```
GET /e/:slug?params...
  → DynamicEndpointsController → 依 slug 找 Endpoint
    → EndpointReplay context
      → ReadOnlySandbox 以全新狀態重放腳本，帶入查詢參數
      → 回傳 JSON 或結構化錯誤
```

`RunScriptTool`（驗證）與 `EndpointReplay`（服務）共用同一個 `ReadOnlySandbox` builder——**同一條執行路徑**，滿足 SPEC「驗證即上線」不變式。

## Tech Stack

| 技術 | gem / 版本 | 所在層 | 用法重點 |
|------|-----------|--------|----------|
| **Kobako** | `kobako` ~> 0.4 _(待 `bundle add` 回填)_ | sandbox / Interaction | mruby-in-WASM 沙盒。`Kobako::Sandbox.new(timeout:, memory_limit:)`；`#define(:NS).bind(:Member, obj)` 綁定唯讀 Service；`#run(target, *args, **kwargs)` / `#eval`；非 wire 型別自動轉 `Handle` 代理供鏈式呼叫；MessagePack 為唯一 wire codec；guest 無 require/網路/檔案/ENV，唯讀為設計保證。每次調用全新狀態。 |
| **RubyLLM** | `ruby_llm` ~> 1.15 _(待 `bundle add` 回填)_ | agents / tools | `EndpointBuilderAgent < RubyLLM::Agent`（macros：`model`、`instructions`、`tools`）；`RunScriptTool < RubyLLM::Tool`（`desc` + `execute`）；指令置於 `app/prompts/`；串流委派 `complete`/`each`。 |
| **LMStudio** | （外部，OpenAI 相容） | — | 預設 `http://localhost:1234/v1`；`config.openai_use_system_role = true`；Agent 用 `model "<id>", provider: :openai, assume_model_exists: true`。 |
| **Hotwire** | `turbo-rails`、`stimulus-rails` | 框架支援 | 生成 UI 與表單互動。 |
| **TailwindCSS** | v4 | 框架支援 | 視覺樣式。 |
| **Action Cable** | `solid_cable` | 框架支援 | 承載 Turbo Stream 即時更新。 |
| **Solid Queue** | `solid_queue` | 框架支援 | `EndpointGenerationJob` 背景執行生成迴圈，不阻塞請求。 |
| **SQLite** | `sqlite3` ~> 2.1 | Data | 主資料庫；額外配置唯讀 reading 連線（見下）。 |

### LLM 設定（Rails.application.config）

LLM 連線設定透過 `Rails.application.config.x`（預設指向 LMStudio）集中管理，並於 `config/initializers/ruby_llm.rb` 套用：

```ruby
# config/application.rb（或 environments/*.rb）
config.x.llm.api_base = ENV.fetch("LLM_API_BASE", "http://localhost:1234/v1")  # 預設 LMStudio
config.x.llm.api_key  = ENV.fetch("LLM_API_KEY", "lm-studio")
config.x.llm.model    = ENV.fetch("LLM_MODEL", "<lmstudio-model-id>")
```

## 唯讀資料存取（兩層唯讀防禦）

兩層各自獨立成立：

1. **能力邊界（第一層）**：沙盒只綁定 `EventQuery`、`MetricQuery` 兩個唯讀查詢角色，沒有任何寫入入口。腳本與宿主互動的唯一管道即這兩個 Service。
2. **SQL 邊界（第二層）**：查詢角色走 Rails 多資料庫的 reading 連線，該連線以 **SQLite 唯讀模式（`mode=ro`）開檔**——寫入在**開檔／驅動層**即被拒，此模式於連線存活期間無法被 guest 翻轉，對應 SPEC「任何到達資料庫的寫入在連線層被拒絕」不變式。

```ruby
# config/database.yml（節錄）
production:
  primary:
    <<: *default
    database: storage/production.sqlite3
  reading:
    <<: *default
    # 以 SQLite URI 唯讀模式開檔：寫入於開檔／驅動層即被拒（連線層保證）
    database: "file:storage/production.sqlite3?mode=ro"
    replica: true   # 並於 AR 層標記唯讀（連線角色為 replica → ActiveRecord::ReadOnlyError）
```

查詢角色以 `connected_to(role: :reading)` 包覆。連線層唯讀由 `mode=ro` 保證（最強、開檔即拒）；`replica: true` 提供 AR 層的額外 `ActiveRecord::ReadOnlyError` 防護。如需執行期再加一道縱深防禦，可於連線建立時補設 `PRAGMA query_only = 1`，但它屬執行期 PRAGMA、強度弱於 `mode=ro`，僅作輔助。

## Dependency Guidelines

- **依賴方向**：Context 依賴 Data 與 Interaction roles；Controller/Job 依賴 Context；Data 不反向依賴 Context。
- **不為易變外部相依預造 port/adapter**：RubyLLM 與 Kobako 直接以原生慣例使用。若日後需多 provider / 多沙盒後端，再於 Context 邊界開 seam。
- **薄 Data**：業務編排留在 Context，model 僅持資料與查詢。

## Patterns

### 兩層唯讀防禦（Two-layer read-only defense）
- **When to apply**：任何讓不可信腳本接觸資料庫的路徑。
- **Shape**：能力邊界（沙盒只綁唯讀 Service）+ SQL 邊界（reading 連線以 `mode=ro` 開檔唯讀），兩層獨立。
- **Canonical example**：`app/sandbox/read_only_sandbox.rb`、`app/sandbox/event_query.rb`。
- **Forces this resolves**：Blast radius（沙盒逃逸／寫入落地會摧毀 Demo 核心論點）。
- **Revisit if**：需支援寫入端點，或改用非 SQLite 資料庫。

### 驗證即上線（Shared execution path）
- **When to apply**：腳本同時用於生成驗證與對外服務。
- **Shape**：驗證（`RunScriptTool`）與服務（`EndpointReplay`）共用同一個 `ReadOnlySandbox` builder。
- **Canonical example**：`app/sandbox/read_only_sandbox.rb`。
- **Forces this resolves**：一致性——驗證時看到的結果等同上線後結果。
- **Revisit if**：驗證與服務需要不同的資源限制或綁定。

### error-as-feedback 自我驗證迴圈
- **When to apply**：讓 LLM 自我修正生成的腳本。
- **Shape**：以 Agent + 單一 `RunScriptTool` 的原生 tool-calling 迴圈實現；沙盒結構化錯誤作為 tool result 餵回，`before_tool_call` 計數封頂達成有限迭代。
- **Canonical example**：`app/agents/endpoint_builder_agent.rb`、`app/tools/run_script_tool.rb`。
- **Forces this resolves**：Rule complexity（自我驗證編排）；避免重造 LLM orchestration。
- **Revisit if**：需要多代理協作，或迴圈需跨多個工具。
```

