# 001 — 為什麼選 NotebookLM(而非官方 API 或自建 RAG)

**決定日期**:2026-08-30

## 決定了什麼

以 `notebooklm-py`(非官方逆向套件)存取 Google NotebookLM,作為大型資料彙整層,並接受其帶來的憑證與穩定性風險。

## 考慮過哪些替代方案

| 方案 | 官方 | 資料被訓練 | 語料庫上限 | 音訊/影片 RAG | 否決理由 |
|---|---|---|---|---|---|
| **Gemini API File Search**(managed RAG) | ✅ GA | **會** | 免費 tier **1 GB** | ❌ 明文不支援 | 見下 |
| Gemini API Files API + 長 context | ✅ | **會** | 20GB/project、48hr TTL | 可(直塞非檢索) | 非 RAG,跨文件綜合品質不足 |
| `agy`(Gemini via Antigravity CLI) | ✅ OAuth | 否 | 受 context window 限 | 一次性餵檔 | 無檢索層,大型彙整品質不足 |
| Gemini Notebook Enterprise API | ✅ | 否 | 大 | 支援 | 需 Gemini Enterprise 授權,使用者沒有 |
| 自寫 Playwright UI 自動化 | ❌ | 否 | 大 | 支援 | 壞得更頻繁,且只有自己能修 |
| **notebooklm-py**(選用) | ❌ | **否** | 大 | ✅ 原生 | — |

## 為什麼選這個

**決定性因素是官方免費 tier 的資料條款。** `ai.google.dev/gemini-api/terms` 原文:

> When you use Unpaid Services... Google uses the content you submit **to provide, improve, and develop Google products and services and machine learning technologies**...
> **human reviewers may read, annotate, and process your API input and output.**
> **Do not submit sensitive, confidential, or personal information** to the Unpaid Services.

而 NotebookLM 消費者版官方說明(`support.google.com/notebooklm/answer/16164461`):

> Your data is protected, and is **not used to train Gemini Notebook unless you provide feedback.**

**方向相反。** 官方路線更穩定,但要求你交出文件給 Google 訓練;非官方路線資料不外流,但會壞。

本專案處理的素材是使用者自己的非公開文件,隱私權重高於穩定性,故選 NotebookLM。若你的素材本來就是公開內容,這個取捨會反過來 —— 官方 API 更穩定,且沒有隱私顧慮。

其次,使用者實測 NotebookLM 在大型多來源彙整的品質明顯優於一次性餵檔 —— 差距來自其 RAG **檢索層**(語料庫可超過 context window、跨文件綜合、引用溯源),不是模型差異。NotebookLM 後端也是 Gemini。

## 已知代價與緩解

| 風險 | 緩解 |
|---|---|
| 逆向 API 隨時失效 | `nb-doctor` exit 2 明確分類;上游維護活躍(每週發版) |
| 憑證等同完整 Google 帳號 | 使用者知情後選擇主帳號;文件記載緊急撤銷路徑 |
| 供應鏈:自動抓未審查新版 | **版本凍結**:MCP 設定由 `uvx` 改指向本機 exe,鎖在 0.8.1 |
| 版本凍結錯過修復 | `nb-doctor` 主動比對 PyPI,落後回 exit 3 |

## 已否決的緩解措施

**憑證目錄 ACL 收緊 —— 試過,已回退。**

`icacls ~/.notebooklm /inheritance:r /grant:r "User:(OI)(CI)F" /T` 會讓檔案變成零授權:`(OI)(CI)` 是繼承旗標,只對目錄有意義,套到葉節點檔案產生的是「只供繼承」的 ACE,對檔案本身不授予權限。結果連擁有者都讀不到,並因阻斷 `__Secure-1PSIDTS` 的輪替寫回導致憑證過期。

已用 `icacls /reset /T` 還原。**不再重做** —— 它在單人機器上擋不住以使用者身分執行的程序,價值本來就低,而破壞性已被證實。真正的防線是版本凍結。
