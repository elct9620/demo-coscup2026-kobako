---
name: Dynamic Read-Only API Generator
description: 自然語言生成、沙盒驗證即上線的動態唯讀 API 端點生成器
colors:
  primary: "#0f2540"
  primary-hover: "oklch(from #0f2540 calc(l + 0.04) c h)"
  primary-active: "oklch(from #0f2540 calc(l + 0.07) c h)"
  secondary: "#51a8dd"
  secondary-hover: "oklch(from #51a8dd calc(l - 0.04) c h)"
  secondary-active: "oklch(from #51a8dd calc(l - 0.07) c h)"
  success: "#68be8d"
  warning: "#f9bf45"
  danger: "#eb7a77"
  info: "#51a8dd"
  surface-base: "#f7fafe"
  surface-sunken: "#f1f4f8"
  surface-raised: "#ffffff"
  surface-overlay: "#ffffff"
  content-default: "#393d43"
  content-muted: "#696f77"
  content-subtle: "#9a9fa5"
  content-strong: "#14161a"
  content-inverse: "#ffffff"
  edge-subtle: "#f1f4f8"
  edge-default: "#dce0e5"
  edge-strong: "#c3c8cd"
typography:
  display:
    fontFamily: "Jost, 'Noto Sans TC', ui-sans-serif, system-ui, sans-serif"
    fontSize: "clamp(2.25rem, 5vw, 3rem)"
    fontWeight: 700
    lineHeight: 1.25
    letterSpacing: "-0.02em"
  headline:
    fontFamily: "Jost, 'Noto Sans TC', ui-sans-serif, system-ui, sans-serif"
    fontSize: "1.875rem"
    fontWeight: 600
    lineHeight: 1.25
    letterSpacing: "-0.01em"
  title:
    fontFamily: "Jost, 'Noto Sans TC', ui-sans-serif, system-ui, sans-serif"
    fontSize: "1.25rem"
    fontWeight: 600
    lineHeight: 1.375
  body:
    fontFamily: "Jost, 'Noto Sans TC', ui-sans-serif, system-ui, sans-serif"
    fontSize: "1rem"
    fontWeight: 400
    lineHeight: 1.5
  label:
    fontFamily: "Jost, 'Noto Sans TC', ui-sans-serif, system-ui, sans-serif"
    fontSize: "0.875rem"
    fontWeight: 500
    lineHeight: 1.375
  code:
    fontFamily: "'JetBrains Mono', ui-monospace, monospace"
    fontSize: "0.875rem"
    fontWeight: 400
    lineHeight: 1.625
rounded:
  none: "0"
spacing:
  base: "0.25rem"
  sm: "0.5rem"
  md: "1rem"
  lg: "1.5rem"
  xl: "3rem"
components:
  button-primary:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.content-inverse}"
    rounded: "{rounded.none}"
    padding: "0.75rem 1.25rem"
    typography: "{typography.label}"
  button-primary-hover:
    backgroundColor: "{colors.primary-hover}"
  button-primary-active:
    backgroundColor: "{colors.primary-active}"
  button-secondary:
    backgroundColor: "{colors.surface-raised}"
    textColor: "{colors.primary}"
    rounded: "{rounded.none}"
    padding: "0.75rem 1.25rem"
    typography: "{typography.label}"
  field:
    backgroundColor: "{colors.surface-raised}"
    textColor: "{colors.content-default}"
    rounded: "{rounded.none}"
    padding: "0.625rem 0.75rem"
    typography: "{typography.body}"
  panel:
    backgroundColor: "{colors.surface-raised}"
    textColor: "{colors.content-default}"
    rounded: "{rounded.none}"
    padding: "1rem"
  log-entry:
    backgroundColor: "{colors.surface-raised}"
    textColor: "{colors.content-default}"
    rounded: "{rounded.none}"
    padding: "0.75rem"
    typography: "{typography.code}"
---

# Design System: Dynamic Read-Only API Generator

## 1. Overview

**Creative North Star: "和式實驗筆記 — The Lab Notebook"**

這是一本工程師的實驗筆記攤在冷白紙上：自然語言進來，本地 LLM 在沙盒裡反覆書寫、試跑、被結構化錯誤糾正、收斂成一支可上線的唯讀腳本——而整個過程像鋼筆在方格紙上留下的痕跡，**毫不遮掩地寫在頁面上讓人看見**。墨水用的是日本傳統色：Kon 紺的深藍是主筆，GunJyo 群青是補注，Wakatake 若竹、Tamago 玉子、JinZamOmi 珊瑚則標記成功、警示與失敗。沒有圓角、沒有陰影、沒有漸層——一切都是銳利的版面與精準的套印。

筆記的可信來自誠實：頁面上看到的腳本，就是上線後重放的腳本；驗證時所見，即上線後結果。介面不替工程說好話，而是把工程攤開來給人看。這份透明本身就是「魔法」——自然語言到上線端點的順暢路徑全程可讀，沒有黑箱。

這個系統明確拒絕：通用預設 Tailwind 的 indigo-600 按鈕與灰階文字、一看就知是 AI 生成的模板化畫面、賣相 SaaS 官網的漸層大標與行銷買詞、以及為動而動的炫技動畫。它要像一份精準、克制、上得了投影幕後排都讀得清楚的工程文件。

**Key Characteristics:**
- **銳角即品牌**：所有元件 `border-radius: 0`，零圓角是設計語言而非疏漏。
- **冷白紙上的傳統色墨**：日本傳統色作為精準的語意墨水，而非裝飾。
- **扁平、靠分層與邊框造深度**：完全不用 shadow，用 surface 三層 + 1px/2px 邊框。
- **mono 是操作層**：JetBrains Mono 承載 Generation Log 與腳本——demo 的主角。
- **過程可見**：串流的生成 Log 是主舞台，不是附屬資訊。
- **投影幕優先**：高對比、大字級、克制而精準的動態。

## 2. Colors

冷調近白紙張上的日本傳統色墨——深藍主筆，群青補注，三支狀態色清楚分辨成功、警示與失敗。

### Primary
- **Kon Navy 紺** (`#0f2540`)：主品牌色。主要動作（生成、提交）、強調文字、品牌標記。hover 在 OKLCH L\* 提亮 +0.04（`oklch(from #0f2540 calc(l + 0.04) c h)`），active +0.07——近黑的品牌色「變亮」表示被按下。

### Secondary
- **GunJyo Blue 群青** (`#51a8dd`)：補注用的支援色。連結、資訊提示、次要強調、`info` 狀態。hover 在 OKLCH L\* 加深 -0.04，active -0.07——明亮的色「變暗」表示互動。

### Tertiary (Status inks)
- **Wakatake Green 若竹** (`#68be8d`)：`success`——生成成功、端點上線。
- **Tamago Amber 玉子** (`#f9bf45`)：`warning`——生成中、等待、需注意。
- **JinZamOmi Coral 珊瑚** (`#eb7a77`)：`danger`——生成失敗、沙盒拒寫、錯誤回饋。

### Neutral
- **Cool Paper** (`#f7fafe`, `surface-base`)：頁面背景，最低層的紙。微藍冷白，不是暖米色。
- **Paper Sunken** (`#f1f4f8`, `surface-sunken`)：凹陷層——程式碼區塊、井狀容器、insets。
- **Paper Raised / Overlay** (`#ffffff`, `surface-raised` / `surface-overlay`)：抬升的卡片、面板；浮層（選單、對話框）需配邊框。
- **Ink** (`#393d43`, `content-default`)：內文預設前景。對冷白 ≈10:1。
- **Ink Strong** (`#14161a`, `content-strong`)：最強文字——強調標題。
- **Ink Muted** (`#696f77`, `content-muted`)：次要文字。對冷白 ≈5.3:1，可作內文。
- **Ink Subtle** (`#9a9fa5`, `content-subtle`)：placeholder／disabled 專用。對冷白僅 ≈2.6:1。
- **Edges** (`#f1f4f8` subtle / `#dce0e5` default / `#c3c8cd` strong)：分隔線與邊框三級。

### Named Rules
**The One Ink Rule.** 任一畫面只讓一支墨當主筆（多半是 Kon 紺）。群青與三支狀態色是補注，不爭主角；狀態色只在對應狀態出現，不拿來裝飾。

**The Projector Floor Rule.** `content-subtle` (`#9a9fa5`, 2.6:1) 只能用在 placeholder 與 disabled。任何「要被讀」的文字——尤其投影幕後排——一律用 `content-muted` 或更深。淺灰絕不為了精緻而當內文。

## 3. Typography

**Display / Body Font:** Jost（幾何無襯線，搭 Noto Sans TC 處理 CJK，fallback `ui-sans-serif, system-ui`）
**Code / Mono Font:** JetBrains Mono（搭 `ui-monospace`）

**Character:** 單一幾何無襯線（Jost）以字重與字級拉開層級，CJK 交給 Noto Sans TC；對比軸不是 serif/sans，而是**幾何 sans × 等寬 mono**——版面是冷靜的編輯排版，操作與程式碼層則切到 JetBrains Mono，讓「機器在工作」這件事在字體上就被看見。

### Hierarchy
- **Display** (700, `clamp(2.25rem, 5vw, 3rem)`, 1.25, `-0.02em`)：頁面主標題（如「Generate a Read-Only API Endpoint」）。Jost 幾何字大字重，銳利。
- **Headline** (600, `1.875rem`/text-3xl, 1.25)：區段標題（「Generation Status」）。
- **Title** (600, `1.25rem`/text-xl, 1.375)：卡片／面板標題、小節標。
- **Body** (400, `1rem`/text-base, 1.5)：內文與需求描述。內文寬度上限 65–75ch。
- **Label** (500, `0.875rem`/text-sm, 1.375)：按鈕文字、欄位標籤、狀態標籤。句式大小寫，不用全大寫。
- **Code** (400, `0.875rem`/text-sm, 1.625)：Generation Log、生成的腳本、端點 URL。`leading-relaxed` 讓串流的多行內容好讀。

### Named Rules
**The Mono-Is-Machine Rule.** 凡是「機器產物」——LLM 訊息、tool call、生成的 mruby 腳本、沙盒錯誤、端點 URL——一律 JetBrains Mono。人寫的描述與介面文案用 Jost。字體本身就標示了「誰寫的」。

**The No-Caps-Sentence Rule.** 全大寫只用於 ≤4 字的標籤或徽章。禁止全大寫內文，禁止在每個區段上方放 tracked uppercase eyebrow。

## 4. Elevation

**完全不使用 shadow。** 這是一套扁平系統，深度由兩件事構成：(1) 表面色調分層——`surface-base` (#f7fafe) < `surface-sunken` (#f1f4f8) < `surface-raised` / `overlay` (#ffffff)；(2) 邊框——hairline 1px (`edge-default` #dce0e5) 與 emphasis 2px (`edge-strong` #c3c8cd / 互動時 `secondary`)。如同筆記本的紙、方格與墨線，層次來自版面而非投影出的陰影。

### Named Rules
**The Flat Paper Rule.** 表面在靜止時一律扁平、無陰影。深度只靠 surface 分層與 1px 邊框表達；浮層（選單、對話框）用 `surface-overlay` + 1px 邊框界定，不靠 box-shadow。

**The Ruled-Line Border Rule.** 邊框是結構線，恆為完整四邊或單純的分隔線。禁止用 >1px 的 `border-left`／`border-right` 當彩色側邊條。

## 5. Components

### Buttons
- **Shape:** 銳角，`border-radius: 0` (`rounded.none`)。永不圓角。
- **Primary:** `surface` = Kon Navy (`#0f2540`)，文字 `content-inverse` (#fff)，padding `0.75rem 1.25rem`，Label 字級。
- **Hover / Focus:** hover → `primary-hover`（OKLCH L\* +0.04）；active → `primary-active`（+0.07）。focus-visible → 2px `secondary` (#51a8dd) outline，offset 2px。轉場 `background 160ms` ease-out。
- **Secondary / Ghost:** `surface-raised` 底、`primary` 文字、1px `edge-default` 邊框；hover 底色切 `surface-sunken`。

### Cards / Containers (Panels)
- **Corner Style:** `border-radius: 0`。
- **Background:** `surface-raised` (#fff) 浮在 `surface-base` (#f7fafe) 上。
- **Shadow Strategy:** 無陰影（見 Elevation）。
- **Border:** 1px `edge-default` (#dce0e5)。
- **Internal Padding:** `1rem` (md)。

### Inputs / Fields
- **Style:** `surface-raised` 底、1px `edge-default` 邊框、`border-radius: 0`、padding `0.625rem 0.75rem`、Body 字級。
- **Placeholder:** 用 `content-muted` (#696f77) 而非 `content-subtle`——投影幕要讀得到。
- **Focus:** 邊框切 2px `secondary` (#51a8dd)（emphasis border-width），無 glow。
- **Error / Disabled:** error → 邊框 `danger` (#eb7a77) + 下方 `danger` 文字訊息；disabled → `content-subtle` 文字、`surface-sunken` 底。

### Status Badge（三態：pending / succeeded / failed）
- **Style:** 銳角徽章，背景用對應狀態色的淡色調（同色相低彩度），文字用該色相的深調——絕不灰字配彩底。
- **三信號原則:** 顏色 + 圖示 + 文字標籤三者齊備。`warning`(玉子) 配旋轉指示器＝生成中；`success`(若竹) 配勾＝上線；`danger`(珊瑚) 配叉＝失敗。色盲與投影幕都讀得懂。

### Generation Log Entry（Signature Component）
這是 demo 的主角。串流進來的每一則 LLM 訊息／tool call／沙盒結果。
- **Style:** `surface-raised` 底、1px `edge-default` 邊框、`border-radius: 0`、padding `0.75rem`、**JetBrains Mono / Code 字級**。
- **Role 標籤:** 頂部一行小 Label（Jost, `content-muted`）標示 assistant / tool / user。
- **內容:** 腳本與 tool 參數用 mono 保留排版（`white-space: pre-wrap`）。
- **Motion:** 新訊息進場以 `translateY(4px)` + fade、ease-out-expo、stagger 串接（見 Do's）。這是本系統唯一被允許的編排式動態，因為它服務「過程即主角」。

### Endpoint URL / Code chip
- 生成成功後的端點 URL 與腳本：JetBrains Mono、`surface-sunken` 底、銳角、可選取。URL 用 `secondary`(群青) 作連結色。

## 6. Do's and Don'ts

### Do:
- **Do** 所有元件用銳角 `border-radius: 0`——這是 0-radius 品牌語言，不是漏設。
- **Do** 維持扁平：深度靠 `surface-base`/`sunken`/`raised` 分層 + 1px/2px 邊框，**不用任何 box-shadow**。
- **Do** 讓 Kon Navy 當每個畫面唯一的主筆（One Ink Rule）；狀態色只在對應狀態出現。
- **Do** 所有「機器產物」（LLM 訊息、tool call、腳本、錯誤、端點 URL）一律 JetBrains Mono（Mono-Is-Machine Rule）。
- **Do** 內文用 `content-default` (#393d43) 或更深；placeholder 用 `content-muted` (#696f77)，投影幕讀得到（Projector Floor Rule）。
- **Do** 狀態同時給顏色＋圖示＋文字三信號。
- **Do** 動態用 ease-out 指數曲線、無彈跳；串流 Log 的逐則 stagger 進場是唯一被允許的編排。
- **Do** 每個動畫都附 `prefers-reduced-motion: reduce` 的淡入或瞬切替代；揭露動畫必須建立在「預設即可見」之上。

### Don't:
- **Don't** 用通用預設 Tailwind 的樣子——`indigo-600` 按鈕、灰階文字、`rounded-md`、白底細邊框卡片。**目前這套 UI 就是反例**，要被取代。
- **Don't** 產出一看就知是 AI 生成的模板化畫面（eyebrow kicker、01/02/03 編號區段、相同尺寸的 icon 卡片網格、hero-metric 模板）。
- **Don't** 走賣相 SaaS landing：漸層大標、`background-clip: text` 漸層字、行銷買詞（streamline／empower／seamless／transform）。這是工具不是官網。
- **Don't** 過度炫技動畫：彈跳／彈簧緩動、滿天玻璃擬態、為動而動——上台 demo 時會干擾觀眾理解生成過程。
- **Don't** 用圓角、用陰影、用 >1px 的彩色側邊條（border-left/right stripe）。
- **Don't** 把 `content-subtle` (#9a9fa5, 2.6:1) 用在任何要被讀的文字。
- **Don't** 用顏色單獨表達狀態（色盲與投影色偏會失效）。
- **Don't** 全大寫內文，或在每個區段上方放 tracked uppercase eyebrow。
