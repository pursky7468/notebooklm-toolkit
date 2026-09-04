# notebooklm-toolkit

把 Google NotebookLM 包成**確定性 CLI 工具包**。大型文件 / 音訊 / 影片先進 NotebookLM 做彙整,只把摘要交給 LLM agent,原始素材永不進入 agent 的 context。

日常操作**零 LLM token**。agent 只在兩個點介入:讀最小結構化描述後**決定該問什麼問題**,以及**工具壞掉時維護**。

---

> ## ⚠️ 先讀這段再決定要不要用
>
> **這個工具依賴非官方的逆向工程套件。** 底層 [`notebooklm-py`](https://github.com/teng-lin/notebooklm-py) 走的是 Google 內部的 `batchexecute` RPC 端點 —— 也就是 NotebookLM 網頁前端自己在打的那個介面。沒有官方 API、沒有 API key、沒有規格文件。
>
> **三件你必須知道的事:**
>
> 1. **它會壞。** Google 改前端就可能失效,而且沒有任何保證或修復時程。同類的瀏覽器自動化專案就在 2026-07 的改名事件中整個死掉。
> 2. **憑證是你的完整 Google 帳號 session。** 存在 `~/.notebooklm/profiles/default/storage_state.json`,**明文 JSON**,而且 **session cookie 會繞過 2FA**。拿到那個檔案等於登入你的 Google 帳號。**強烈建議用次要帳號。**
>    緊急撤銷:`myaccount.google.com` → 安全性 → 登出所有工作階段。
> 3. **使用自動化存取可能違反 Google 服務條款**,後果是帳號停權。條款是 Google 與**你**之間的契約 —— 執行這個工具的人自行承擔。
>
> **不要使用 master-token / `[headless]` 模式。** 上游那條路徑會冒充 Google Home 的 Android app 來換取長期憑證,那是範圍極廣、難以撤銷的裝置級 token。本工具包不使用它,你也不該開。
>
> ## 📌 這個專案的定位
>
> 這是**特定時間點(2026-09)的實作筆記與參考實作**,不是長期維護的產品。
>
> - **不承諾維護**。Google 改版讓它失效時,可能不會有修復。
> - **沒有做逆向工程** —— RPC 逆向全部在上游 `notebooklm-py`(MIT)。這裡只有包裝腳本。
> - **Windows PowerShell 5.1 專用**。跨平台請直接用上游的 Python CLI。
> - 真正的內容在 [`VERIFY.md`](VERIFY.md)(踩過的坑與實測數據)與 [`decisions/`](decisions/)(為什麼這樣選)。**腳本只是佐證。**

---

## 前置需求

- `notebooklm-py` 0.8.1(已透過 `uv tool install` 安裝,**版本刻意凍結**)
- 已執行 `notebooklm login` 完成 Google 帳號驗證
- Windows PowerShell 5.1

## 四支腳本

### nb-inspect — agent 判斷問題的輸入

```powershell
.\nb-inspect.ps1                              # 列出所有 notebook(id + 標題)
.\nb-inspect.ps1 -Notebook <id>               # 單一 notebook 的標題與 source 清單
.\nb-inspect.ps1 -Notebook <id> -Json         # 機器可讀
```

輸出**只含** `id / title / created_at / is_owner / sources[type,title,url]`,以顯式白名單投影,不會洩漏任何 source 內容本文。

### nb-ingest — 素材入庫

```powershell
.\nb-ingest.ps1 -Path "D:\docs\report.pdf" -Notebook <id>   # 單檔
.\nb-ingest.ps1 -Path "D:\docs" -Notebook <id>              # 資料夾(遞迴 + 副檔名白名單)
.\nb-ingest.ps1 -Watch                                       # 依 config.json 的 watchTasks 掃描
```

已處理檔案以「路徑 + 大小 + mtime」記錄在 `state\ingest-state.json`,重跑不會重傳;檔案改動後會自動重傳。

### -Wait:等待來源處理完成

上傳只是把來源排進佇列,NotebookLM 還要解析或**轉錄**。音訊/影片尤其明顯 —— 40 分鐘的節目幾秒就上傳完,但之後會停在 `preparing` 一分鐘以上。ingest 完立刻 digest 會問到空的。

```powershell
.\nb-ingest.ps1 -Path "D:\podcast" -Notebook <id> -Extensions @('mp3') -Wait
.\nb-ingest.ps1 -Watch -Wait -WaitTimeoutSeconds 900     # 排程建議加上
```

輪詢所有本次寫入過的 notebook,直到沒有來源處於 `preparing` / `processing` / `pending` / `uploading`。有來源處理失敗或逾時 → exit 1。

**排程一律加 `-Wait`**,否則下游的 digest 會拿到還沒轉錄完的來源。

### nb-digest — 提問並輸出摘要

```powershell
.\nb-digest.ps1 -Notebook <id> -Question @('核心論點是什麼?', '有哪些矛盾?')
.\nb-digest.ps1 -Notebook <id> -Question @('...') -NewConversation   # 破壞性,見下
```

輸出 `.md` 到 `out\`(或 config 的 `digestOutputDir`),主控台印出完整路徑。

問題經 **stdin**(`--prompt-file -`)傳給 notebooklm,不走 argv,因此含引號、換行、中文都不會被 PowerShell 的參數處理破壞。

### -Brief:壓縮輸出

NotebookLM 預設回答很長。`-Brief` 會在每個問題後附加簡潔指令:

```powershell
.\nb-digest.ps1 -Notebook <id> -Question @('...') -Brief
```

實測(同一個 notebook、同樣 4 個問題):

| 模式 | 輸出大小 |
|---|---|
| 預設 | 50,791 bytes |
| `-Brief` | 2,379 bytes(**21 倍**) |

關鍵事實與結論都保留,但引用不可靠:

> **`-Brief` 的引用溯源不保證存在。** 實測兩種結果都出現過:AI 週報那次(對話已進行到第 12 輪)回傳 `references: 0`,內文的 `[n]` 標記無法解析;podcast 那次(全新對話)則正常回傳 10/6/4 筆引用。目前無法確定觸發條件,推測與對話輪次有關。**需要保證引用溯源時不要加 `-Brief`。**

### nb-doctor — 健檢與故障分類

```powershell
.\nb-doctor.ps1
.\nb-doctor.ps1 -Json
```

| exit code | 意義 | 誰處理 |
|---|---|---|
| 0 | 正常 | — |
| 1 | auth 失效 | **使用者**:重跑 `notebooklm login` |
| 2 | RPC / 解碼失敗 | **agent**:上游逆向介面壞了,需要改碼 |
| 3 | 上游有新版 | 使用者決定是否解凍升級 |

適合掛排程。輸出**不含**任何 cookie / token / 憑證欄位值,只有檔案路徑與有效性判定。

## connectors/ — 外部資料來源

工具包本身不知道素材從哪來。`connectors/` 放把特定資料源接進來的腳本。

### B 類:AI 新聞週報

```powershell
# 累積到既有 notebook(建議)
.\connectors\Invoke-WeeklyAiNews.ps1 -Notebook <id> -PerDay 2 -Days 7

# 或每批開新的
.\connectors\Invoke-WeeklyAiNews.ps1 -NewNotebook -PerDay 2
```

流程:憑證前置檢查 → 取本週 URL → `nb-ingest -Wait` → `nb-inspect`。跑完印出 notebook 描述,**由 agent 讀了再決定要問什麼**,然後自行呼叫 `nb-digest`。

`Get-AiNewsUrls.py` 透過 `x-ai-news-researcher` 自己的 `NewsStore.query_posts` 取資料,排序慣例(`relevance_score` desc)留在該專案裡,不在這邊重寫 SQL。

```powershell
# 先指定來源專案的 backend 路徑(或每次呼叫帶 --backend)
$env:AI_NEWS_BACKEND = 'D:\path\to\x-ai-news-researcher\backend'

python .\connectors\Get-AiNewsUrls.py --days 7 --per-day 2          # 每行一個 URL
python .\connectors\Get-AiNewsUrls.py --date-from 2026-08-22 --date-to 2026-08-28 --json
python .\connectors\Get-AiNewsUrls.py --days 14 --top 20            # 整段取前 20 名
```

**為什麼不用 MCP 拿資料**:那個專案的 MCP tool 全是普通 Python 函式加 `@mcp.tool()`,可以直接 import 呼叫,輸出完全相同。走 MCP 協定等於把模型放進迴圈,每次排程都燒 token —— 正好違背這個工具包的目的。

**與該專案既有週報的分工**:它的 `get_weekly_summary` 已經產出一份完成的週報(「這週發生什麼」)。NotebookLM 這邊放的是**原始文章全文的可查詢語料庫**,能回答週報答不了的追問;語料庫跨週累積後,還能問「這個主題是從哪一週開始出現的」。

### 憑證自我修復

`Invoke-WeeklyAiNews.ps1` 開頭會跑 `nb-doctor`,回 exit 1 就自動執行 `notebooklm login` 再重驗。**只要瀏覽器 profile 的 Google session 還有效,`notebooklm login` 是完全非互動的**(直接重新匯出 cookie),所以排程能自己救回過期的憑證。只有連瀏覽器 profile 都失效時才需要人。

背景:`__Secure-1PSIDRTS` 這個輪替 token **只有約 12 分鐘壽命**,錯過續期就會脫鉤。實測一個工作階段內失效過三次(併行呼叫容易搶輪替);單行程循序執行的排程風險低很多,但前置檢查仍值得留著。

## 設定

複製 `config.example.json` 為 `config.json` 後填寫:

- `digestOutputDir` — digest 的 `.md` 落點
- `ingestStateFile` — 去重狀態檔
- `watchTasks[]` — 每個監看任務:
  - `folder` 監看路徑、`extensions` 副檔名白名單
  - `mode: "existing"` + `notebookId` → 累積到既有 notebook
  - `mode: "new"` → 每次執行建立新 notebook(標題含任務名與時間戳)

`config.json` 已列入 `.gitignore`,不會被提交。

## 呼叫方式的注意事項

**在 PowerShell 內直接呼叫**,不要用 `powershell -File`:

```powershell
.\nb-digest.ps1 -Notebook <id> -Question @('a', 'b')     # 正確
powershell -File .\nb-digest.ps1 -Question @('a','b')    # 錯誤:-File 會把陣列攤平成多個字串
```

所有腳本都設了 `PositionalBinding=$false`,參數一律要具名。傳錯會**大聲失敗**,不會靜默把輸出寫到錯誤路徑。

## 輸出可被程式擷取

資料性輸出走 `Write-Output`,日誌(`[INFO]`/`[WARN]`/`[ERROR]`)走 `Write-Host`,所以 stdout 乾淨、可直接擷取:

```powershell
$mdPath = .\nb-digest.ps1 -Notebook <id> -Question @('...')
$meta   = (.\nb-inspect.ps1 -Notebook <id> -Json) -join "`n" | ConvertFrom-Json
```

## config.json 常見錯誤

**Windows 路徑的反斜線在 JSON 裡必須寫成兩個**:

```json
"folder": "D:\\docs\\inbox"    <- 正確(反斜線寫兩個)
"folder": "D:\docs\inbox"      <- 錯誤,JSON 解析失敗
```

寫錯時 `nb-ingest -Watch` 會明確報「Config file is not valid JSON」並附提示,不會誤報成「沒有 watchTasks」。

## 已知限制

- 底層 `notebooklm-py` 走**逆向的 Google 內部 API**,非官方。Google 改前端即可能失效 —— 這正是 `nb-doctor` exit 2 存在的理由
- 憑證 `~/.notebooklm/profiles/default/storage_state.json` 是完整 Google 帳號 session,等同帳號存取權
- **緊急撤銷**:`myaccount.google.com` → 安全性 → 登出所有工作階段,該憑證立即失效
- 版本刻意凍結在 0.8.1。升級要手動 `uv tool upgrade notebooklm-py`,升級前先看 `nb-doctor` 有沒有回報 exit 3
- `mode: "new"` 的監看任務每次執行都會產生新的 notebook id,而去重狀態以 `notebookId::路徑` 為鍵,因此 `state\ingest-state.json` 會隨執行次數線性成長。這是刻意的(每批要全量上傳),但長期排程下建議定期清理該檔
