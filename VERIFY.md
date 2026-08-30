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

## 已知未驗證項

- `nb-doctor` exit 2(RPC / 解碼失敗)與 exit 3(上游有新版)兩條分支無法在真實環境自然觸發,僅以假 CLI 替身驗過分支邏輯。真正觸發時的行為需待上游實際改版才能確認
