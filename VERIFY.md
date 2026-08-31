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

## 已知未驗證項

- `nb-doctor` exit 2(RPC / 解碼失敗)與 exit 3(上游有新版)兩條分支無法在真實環境自然觸發,僅以假 CLI 替身驗過分支邏輯。真正觸發時的行為需待上游實際改版才能確認
