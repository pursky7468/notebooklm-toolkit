# 驗證紀錄

**最後更新**:2026-08-30
**驗證環境**:Windows 11、PowerShell 5.1、notebooklm-py 0.8.1、帳號 purskyrone@gmail.com

驗證分兩輪。第一輪由實作 agent 執行,因憑證 ACL 事故無法呼叫真實 API,多數項目以「假 CLI 替身」驗證。
第二輪(本文)由主對話在憑證修復後,以**真實 NotebookLM API** 重跑,並修掉真實 API 才暴露出來的問題。

測試用 notebook 均以 `__toolkit_test_` 開頭,驗證後已刪除。使用者原有的 11 個 notebook 全程未被寫入。

---

## 真實 API 驗證結果

| 驗收項 | 指令 | 結果 |
|---|---|---|
| nb-doctor 正常路徑 | `.\nb-doctor.ps1` | exit 0,回報 auth valid / 0.8.1 為最新 |
| nb-doctor auth 失效 | (憑證 ACL 損壞期間自然觸發) | exit 1,訊息指向 `notebooklm login` |
| nb-inspect 列出全部 | `.\nb-inspect.ps1` | 11 個 notebook,exit 0 |
| nb-inspect 單一 notebook | `.\nb-inspect.ps1 -Notebook df60bb73` | 標題 + 10 個 source,**無任何 source 內容本文** |
| nb-inspect JSON | `.\nb-inspect.ps1 -Notebook <id> -Json` | 可 `ConvertFrom-Json`,欄位僅 `id/title/created_at/is_owner/sources` |
| nb-ingest 首次上傳 | `.\nb-ingest.ps1 -Path <dir> -Notebook <id>` | success 2 / skip 0 / fail 0 |
| nb-ingest 重跑不重傳 | 同上,第二次 | success 0 / skip 2 / fail 0 |
| nb-ingest 改動後重傳 | 改動 alpha.txt 後重跑 | success 1 / skip 1 / fail 0 |
| nb-ingest 副檔名白名單 | `-Extensions @('txt')`(不帶點) | .txt 命中、.log 略過 |
| nb-ingest TaskName 打錯 | `-Watch -TaskName "typo-task-name"` | exit 1 並明確報錯 |
| nb-ingest TaskName 正確 | `-Watch -TaskName "real-task"` | exit 0,正常執行 |
| nb-digest 多問題 + 引號 + 換行 | `-Question @($q1, $q2)` | 兩題完整送達,問題文字未被截斷 |
| nb-digest 輸出檔 | 同上 | `.md` 實際產生,含問答與引用 |
| nb-digest 路徑可擷取 | `$out = .\nb-digest.ps1 ...` | 變數成功接到完整路徑 |
| 輸出無 BOM | 讀 `.md` 與 `state.json` 前 3 bytes | 皆非 `EF BB BF` |

## 真實 API 才暴露、已修復的問題

| # | 問題 | 檔案 | 說明 |
|---|---|---|---|
| 1 | `list --json` 回 `{"notebooks":[...]}` 非裸陣列 | nb-inspect.ps1 | 原碼假設裸陣列,列表模式輸出空白。已加解包並保留裸陣列容錯 |
| 2 | `$PSScriptRoot` 在 param() 預設值中為空 | nb-digest.ps1, nb-ingest.ps1 | 導致 `Join-Path` 收到空字串而中止。已改為 param 區塊之後解析 |
| 3 | 參數 positional 綁定污染 `$OutDir` | 全部四支 | `-Question $a, $b` 會讓 `$b` 綁到 `$OutDir`,靜默寫檔到亂路徑。已全面加 `PositionalBinding=$false`,改為大聲失敗 |
| 4 | References 倒出原始 JSON(含來源全文) | nb-digest.ps1 | 違背 token 最小化目的。已改為 `[N] 檔名 -- 120 字截斷`,單筆從 ~700 bytes 降到 ~150 bytes |
| 5 | config JSON 解析失敗誤報「No watchTasks」 | nb-ingest.ps1 | 使用者手寫 config 時會被導向錯誤方向。已改為明確報 JSON 無效並提示反斜線要寫兩個 |
| 6 | 資料性輸出走 `Write-Host` 無法被擷取 | nb-digest.ps1, nb-inspect.ps1 | 呼叫端拿不到 `.md` 路徑與 JSON。已改 `Write-Output`,日誌仍留在 `Write-Host` |

## 跨模型 review(agy / Gemini)findings 與處置

| # | 嚴重度 | 問題 | 處置 |
|---|---|---|---|
| 1 | 高 | `-TaskName` 未命中時全部 `continue`,exit 0 假陽性 | **已修**,改為 exit 1 並實測 |
| 2 | 中 | nb-doctor:auth check 非 0 退出但未命中已知分支時會落到 Healthy | **已修**,加 ExitCode 兜底歸類 code 2 |
| 3 | 中 | stdin 寫入未捕捉 broken pipe,子行程早退會讓腳本 crash 並掩蓋真實錯誤 | **已修**,包 `IOException` / `ObjectDisposedException` |
| 4 | 中 | `Get-Command` 可能回傳陣列導致 `$psi.FileName` 型別異常 | **已修**,加 `Select-Object -First 1` |
| 5 | 低 | 副檔名白名單未標準化前導點,config 寫 `"pdf"` 會全部略過 | **已修**,加 `ConvertTo-NormalizedExtensions`,實測 `txt` 可命中 |
| 6 | 低 | PS 5.1 `Set-Content -Encoding UTF8` 會寫 BOM | **已修**,改 `File::WriteAllText` + no-BOM,實測確認 |
| 7 | 低 | nb-digest 的 `source list` 解析缺少 nb-inspect 已有的容錯 | **已修**,比照補上 |
| 8 | 低 | `mode: "new"` 任務使 state 檔線性成長 | **不修**,這是設計取捨(每批要全量上傳);改在 README 記載並建議定期清理 |

review 同時確認:全專案無任何 `notebook delete` 指令、憑證僅由底層 CLI 內部讀取、腳本全面使用 `-LiteralPath`。

## 實際素材測試(x-ai-news-researcher 週報,2026-08-30)

素材:`x-ai-news-researcher` 的 `backend/dev.db`,取 2026-08-22~28 每天 `relevance_score` 第一名的 URL(專案自身的排序慣例,見 `app/store/news_store.py:248`),共 7 筆。

| 步驟 | 結果 |
|---|---|
| `nb-ingest -Path <7 個 URL 陣列>` | success 7 / skip 0 / fail 0,**單次呼叫** |
| `nb-inspect` | 正確列出 7 個 source,並暴露 2 個資料問題(見下) |
| `nb-digest`(預設) | 50,791 bytes,4 題皆有引用(33/20/30 筆) |
| `nb-digest -Brief` | 2,379 bytes(21 倍壓縮),關鍵事實保留,但 `references: 0` |

**這次測試發現並修掉的問題:**

1. `-Path` 原為單一 `[string]`,批次 URL 要呼叫 7 次 → 改為 `[string[]]`,一次呼叫、一次 state 儲存、一份合併摘要
2. `-Brief` 的格式指令原本寫成中文字串常值,而全部 `.ps1` 皆無 BOM,PS 5.1 以 cp950 解碼導致字串被破壞、腳本無法解析(doctrine R3 的字串常值版本)→ 改為 ASCII

**工作流誠實性驗證:** 7 個來源中有 2 個實際無內容(r/MachineLearning 貼文已被版主刪除、HN 只抓到導覽列)。digest 在被問到時**正確指認這兩筆並未編造內容**,兩種模式皆然。

## A 類實測:cv/companies 知識庫(2026-08-31)

素材:`C:\GitSource\cv\companies` 的 28 份 markdown(6 家公司,各含 job / apply / cover_letter / interview / log)。**未包含** `99_公司機密_勿外流/` 與 `journal/`。

| 步驟 | 結果 |
|---|---|
| `nb-ingest -Watch -TaskName cv-companies` | 首次 27/28,1 筆遇上游 503 |
| 重跑 | skip 27 / success 1 —— **暫時性失敗自動重試,未重傳全部** |
| `nb-inspect` | 28 筆,標題含公司路徑 |
| `nb-digest`(4 題,預設模式) | 36,872 chars,135 筆引用 |

**這次發現並修掉的問題:**

1. **巢狀目錄的來源標題全部塌成檔名** —— 6 個 `_company.md`、9 個 `job.md`,公司身分完全遺失,引用會變成無法辨識的 `[1] job.md`。修法:`Get-SourceTitle` 以 ingest 根目錄為基準計算相對路徑,透過 `source add --title` 傳入。
2. **修法本身第一次寫壞而且被靜默吞掉** —— `-replace '\', '/'` 的單一反斜線是無效 regex,PowerShell 拋錯後被空的 `catch { }` 吃掉,退回檔名,看起來「正常」。改用 `String.Replace([char]92, [char]47)` 避開跳脫,並讓 catch 發出 WARN 而非靜默。

**上游偶發不一致**:28 筆中有 1 筆(`德倫思管理顧問/aoi-sw-lead/apply.md`)標題有送出但未被套用,顯示為裸 `apply.md`。本地函式未拋錯(無 WARN),判定為上游行為,不影響內容可用性。

**跨文件綜合的實際價值**(單檔閱讀找不到的):digest 指出多處投遞素材的前後不一致 —— 同團隊兩職缺的定位衝突、cover letter 早期草稿的「full cycle」過度宣稱、「MES 交握協議由我定義」的角色誇大、年資敘述精確度落差。全部附引用可回溯到具體檔案。

## C 類實測:podcast 音訊(2026-08-31)

素材:Apple 台灣 podcast 排行榜第 1 名《豬探長推理故事集》。刻意選同一案件的上下兩集(EP.131/132 袖珍娃娃屋奇案,各約 20 分鐘)以測試跨集綜合,另加一集無關的 SP.11 特別集作為幻覺對照組。

| 步驟 | 結果 |
|---|---|
| 下載兩集 mp3(38 MB) | 由 RSS enclosure 取得 |
| `nb-ingest -Extensions @('mp3')` | success 2 / skip 1(`.json` 被白名單擋掉),20 秒 |
| 轉錄等待 | 上傳後狀態為 `preparing`,約 1–2 分鐘後轉為 `ready`,type 由 `unknown` 變 `media` |
| `nb-ingest ... -Wait`(第三集) | 輪詢 3 次共約 20 秒後確認 ready,總計 40 秒,exit 0 |
| `nb-digest -Brief`(3 題) | 全部正確,含引用 |

**跨集綜合驗證(核心能力)**:第 2 題「上集埋下哪些線索,到下集才揭曉意義」被正確回答 —— 釦子沾金粉、請警衛吃火鍋、預告信時間異常三條線索,各自對應到下集的解釋,**引用分別指向正確的集數**。這是單集閱讀無法得出的結論。

**幻覺對照組通過**:第 3 題問無關的 SP.11 是否與本案有關,回答「沒有關聯」並如實描述該集實際內容(粉絲問答),未強行建立連結。

**這次發現並修掉的問題:**

1. **上傳成功不等於可用** —— `nb-ingest` 上傳完即回報 success,但音訊仍在轉錄。排程若 ingest 後立刻 digest 會查到空來源。新增 `-Wait` / `-WaitTimeoutSeconds`:輪詢本次寫入過的所有 notebook 直到無來源處於 preparing/processing/pending/uploading,逾時或有來源失敗則 exit 1。

2. **先前對 `-Brief` 的結論過度斷言** —— 原記載「brief 模式必然失去引用溯源」。本次 podcast 測試(全新對話)brief 模式正常回傳 10/6/4 筆引用,推翻該結論。AI 週報那次回傳 `references: 0` 時對話已進行到第 12 輪,推測與對話輪次有關但未確證。README 與執行時警示均已改為「不保證存在,需要保證時不要用 -Brief」。

## B 類實測:AI 新聞週報 pipeline(2026-09-01)

`connectors/Invoke-WeeklyAiNews.ps1 -NewNotebook -PerDay 2 -Days 7`,端到端 143 秒。

| 步驟 | 結果 |
|---|---|
| 憑證前置檢查 | `nb-doctor` exit 0,略過重新認證 |
| 取 URL | 14 筆(2026-08-22~28,每日前 2 名) |
| 建 notebook | `create --json` 回 `{notebook:{id}}` |
| `nb-ingest -Wait` | 13/14 成功,1 筆 HN 遇 `RPCError rpc_code=9` |
| `nb-inspect` | 印出來源清單供 agent 判斷 |
| `nb-digest -Brief`(4 題) | 3,937 bytes,4 題中 2 題含引用 |

**MCP vs 直接 import 的實測結論**:該專案的 MCP tool 全是普通 Python 函式加 `@mcp.tool()`。`import mcp_server` 後直接呼叫 `get_trending_tools(days=14, limit=3)`,輸出與透過 MCP 協定呼叫**逐字相同**,但零 token。連接器因此改用 `NewsStore.query_posts`,把排序慣例留在來源專案。

**這次發現並修掉的問題:**

1. **`-Wait` 的失敗狀態字串比對錯誤** —— 我寫 `'failed'`,上游實際用 `'error'`。結果 notebook 內有一筆 error 來源時仍印「All sources ready」並回傳成功,正是 `-Wait` 該防止的靜默成功。已改為比對 `error` / `failed` 兩者,並逐筆列出失敗來源的標題。修正後實測:16 筆中偵測到 2 筆 error,exit 1。

2. **add 回報失敗仍會留下空殼來源** —— HN 那筆 `RPCError rpc_code=9` 之後,`source list` 仍出現該筆,`status: "error"`,標題是裸 URL。因為 state 只記錄成功,重跑會再建一筆重複的空殼。目前處置:`-Wait` 會明確報出來,由使用者以 `notebooklm source delete <id>` 清除。未自動刪除 —— 自動刪別人的來源風險高於收益。

**憑證壽命的實測數據**:`__Secure-1PSIDRTS` 輪替 token 到期時間僅約 **0.2 小時(12 分鐘)**,其餘 cookie 為 8760~9555 小時。一個工作階段內憑證失效三次,皆發生在並行呼叫(PowerShell/Bash 交錯、MCP 探測)期間 —— 輪替會使前一個 token 失效,兩個行程同時輪替就有一個被踢掉。單行程循序的排程風險低很多。

**排程自我修復**:`notebooklm login` 在瀏覽器 profile 的 Google session 仍有效時**完全非互動**(直接重新匯出 cookie,印「Already logged in」)。因此 pipeline 開頭以 `nb-doctor` 判定、exit 1 時自動 login 再重驗,可在無人值守下救回過期憑證。

## 已知未驗證項

- `nb-doctor` exit 2(RPC / 解碼失敗)與 exit 3(上游有新版)兩條分支無法在真實環境自然觸發,僅以假 CLI 替身驗過分支邏輯。真正觸發時的行為需待上游實際改版才能確認
