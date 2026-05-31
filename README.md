# COSCUP 2026 - Kobako Demo

展示 **[Kobako](https://github.com/elct9620/kobako)**（mruby-in-WASM 沙盒）如何安全執行不可信腳本的展示專案。場景是「自然語言生成唯讀 API 端點」：本地 LLM 生成的不可信 mruby 腳本在 Kobako 沙盒中試跑驗證，通過後即上線為 `GET /e/:slug`。

| Kobako 特性 | 在這個 Demo 中如何體現 |
|------|------|
| 宿主隔離（無檔案／網路／ENV） | LLM 生成的不可信腳本無法逃逸或讀寫系統 |
| 能力綁定（`define.bind`） | 沙盒只綁唯讀查詢 Service，腳本沒有任何寫入入口 |
| Handle 代理 | 腳本跨沙盒邊界鏈式組合宿主的查詢物件 |
| 每次調用全新狀態 | 端點每次請求都在乾淨沙盒重放，調用間互不汙染 |
| MessagePack 序列化邊界 | 回傳值須可序列化為 JSON，否則視為錯誤回饋給 LLM |

## 使用方式

### 生成表單（首頁 `/`）

展示的入口：操作者不碰程式碼，用一句自然語言下達報表需求。內建範例刻意涵蓋沙盒的各種能力（查詢參數、聚合、明細、相對時間），方便現場快速試不同生成。

```
┌──────────────────────────────────────────┐
│ Generate a read-only API endpoint        │
│ ┌──────────────────────────────────────┐ │
│ │ Count events for the `event` param…  │ │  ← 自然語言需求
│ └──────────────────────────────────────┘ │
│ Try one:  · daily counts  · top 5 names… │  ← 一鍵範例
│ [ Generate endpoint ]                     │
└──────────────────────────────────────────┘
```

### 生成狀態頁（`/endpoints/:id`）

展示的核心看點：把「LLM 生成 → 沙盒試跑 → 錯誤回饋 → 修正重試」的自我驗證迴圈即時攤開，讓腳本如何在沙盒裡被驗證、收斂的過程被看見，而非黑箱。

```
┌──────────────────────────────────────────┐
│ Generation status                         │
│ Requirement: Count events over last days  │
│ [● Generating… / ✓ live / ✗ failed]       │  ← 狀態徽章
│ ── Generation log ──────────────── ●live ─│
│  ▸ LLM: <腳本 v1>                          │
│  ▸ sandbox: error → 餵回                    │  ← error-as-feedback
│  ▸ LLM: <腳本 v2>                          │     每輪即時串流
│  ▸ sandbox: ok → ✓ 上線 /e/abc123          │
└──────────────────────────────────────────┘
```

### 已上線端點列表（`/endpoints`）

證明生成的端點確實在線上服務，並提供重跑展示的工具。「灌入事件」走正常路徑（不經沙盒）寫入新資料，示範端點下次呼叫即反映最新狀態；「清空端點」讓你乾淨地重來一次。

```
┌──────────────────────────────────────────┐
│ Live endpoints              2 endpoints   │
│ [ 灌入一批事件 ] [ 清空全部端點 ]            │  ← 維運工具
│ ┌──────────────────────────────────────┐ │
│ │ /e/abc123            2026-05-31 14:02 │ │
│ │ Count events over the last days       │ │  ← 連回生成紀錄
│ │ <腳本內容>                             │ │
│ └──────────────────────────────────────┘ │
└──────────────────────────────────────────┘
```

### 動態端點（`GET /e/:slug`）

對外服務的端點本體（回傳 JSON、無畫面）。每次請求都以全新沙盒重放當初驗證通過的同一份腳本，體現「驗證時所見即上線後所得」。

```
$ curl 'http://localhost:3000/e/abc123?event=page_view&days=7'
{ "data": { "count": 312 }, "meta": { … } }
```

## 環境需求

生成功能依賴本機 [LMStudio](https://lmstudio.ai/)（OpenAI 相容）運行並載入模型，連線設定見 `config/llm.yml`，可用環境變數覆寫。

| 項目 | 預設 | 環境變數 |
|------|------|----------|
| Ruby | 3.4.7（見 `.ruby-version`） | — |
| LLM 端點 | `http://localhost:1234/v1` | `LLM_API_BASE` |
| LLM 金鑰 | `lm-studio` | `LLM_API_KEY` |
| LLM 模型 | `google/gemma-4-26b-a4b` | `LLM_MODEL` |

## 執行

首次以 `bin/setup` 安裝相依、準備資料庫並灌入示範事件；之後以 `bin/dev` 啟動，開啟 `http://localhost:3000` 即是生成表單。

| 指令 | 用途 |
|------|------|
| `bin/setup` | 安裝相依、準備資料庫、灌入示範事件，並啟動開發伺服器 |
| `bin/dev` | 啟動 web（Puma）與 css（Tailwind watch） |
| `bin/rails db:seed` | 重新灌入示範用的分析事件 |

## 測試與檢查

| 指令 | 用途 |
|------|------|
| `bin/rails test` | Minitest 全部 |
| `bin/rubocop` | 風格（rubocop-rails-omakase） |
| `bin/brakeman` | 安全靜態分析 |
| `bin/ci` | 一次跑完整 CI 流程 |

## 文件

- [`SPEC.md`](SPEC.md) — 目標狀態與行為邊界（實作中立）。
- [`docs/architecture.md`](docs/architecture.md) — 技術棧、目錄對應與關鍵實作模式。
