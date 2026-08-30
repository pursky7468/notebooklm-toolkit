# notebooklm-toolkit

把 Google NotebookLM 包成**確定性 CLI 工具包**。大型文件 / 音訊 / 影片先進 NotebookLM 做彙整,只把摘要交給 Claude,原始素材永不進入 Claude context。

日常操作**零 Claude token**。agent 只在兩個點介入:

1. **決定該問什麼問題** —— 讀 `nb-inspect` 的輸出(只有標題與 source 清單,體積與素材大小無關)
2. **工具壞掉時維護** —— 由 `nb-doctor` 的 exit code 觸發

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

### nb-digest — 提問並輸出摘要

```powershell
.\nb-digest.ps1 -Notebook <id> -Question @('核心論點是什麼?', '有哪些矛盾?')
.\nb-digest.ps1 -Notebook <id> -Question @('...') -NewConversation   # 破壞性,見下
```

輸出 `.md` 到 `out\`(或 config 的 `digestOutputDir`),主控台印出完整路徑。

問題經 **stdin**(`--prompt-file -`)傳給 notebooklm,不走 argv,因此含引號、換行、中文都不會被 PowerShell 的參數處理破壞。

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
