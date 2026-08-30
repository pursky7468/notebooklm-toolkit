# 002 — 工具包架構決策

**決定日期**:2026-08-30

## 決定了什麼

包裝 `notebooklm` **CLI**(非 MCP、非 Python library),做成四支 PowerShell 腳本,agent 的介入面縮到兩點。

## 為什麼包 CLI 不包 MCP

CLI 是**唯一能零 token 執行**的介面。MCP 必然要模型在迴圈裡 —— 每次 ingest、每次 digest 都燒 token,直接違背專案目的。

替代方案:
- **直接呼叫 MCP** —— 否決,每次操作燒 token
- **Python 腳本直接 import library** —— 否決,要自己處理 client 生命週期與 auth,多一層自維護相依,且繞過 CLI 已做的錯誤處理

MCP 註冊仍保留,供互動式追問使用(那時模型在迴圈裡是刻意的)。

## token 最小化的核心機制

```
nb-inspect  →  只吐 notebook 標題 + source 清單(不含內容)   ← agent 讀這個
     ↓ agent 判斷該問什麼
nb-digest -Question "..."  →  NotebookLM 做重活  →  輸出 .md
     ↓ Claude 只讀這份摘要
```

**關鍵性質:`nb-inspect` 的輸出體積與素材大小無關。** 素材是 3 小時影片,agent 看到的仍只有一行標題。

替代方案:讓 agent 先讀素材摘要再決定問題 —— 否決,那等於先做一次彙整,把要省的 token 花掉了。

## 為什麼問題不放進 config

使用者明確要求:問題由 agent 每次依素材判斷,不用固定問題集。config 固定問題集適合素材性質一致的情況,但使用者的 notebook 主題差異大(遊戲攻略 / 保單 / AccuPick 技術文件),各自該問的東西不同。

## 為什麼問題走 stdin 而非 argv

PS 5.1 呼叫原生 exe 有兩個已知陷阱:空字串參數被靜默丟棄、`@array` splat 會掉元素。問題文字含引號與換行時風險更高。

改用 `notebooklm ask --prompt-file -` 從 stdin 讀取,完全不經過 argv 處理。

## nb-doctor 用 exit code 分級的理由

直接對應使用者需求「agent 只負責壞掉時維護」。排程跑 `nb-doctor`,只有 exit 2 才需要叫 agent;exit 1 使用者自己重登即可;exit 3 是資訊性提醒。

若只印訊息不分級,排程無法判斷該不該升級處理。

## `--new` 預設關閉

`notebooklm ask --new` 會刪除 notebook 現有的 server-side 對話且不可復原,會清掉使用者在網頁端的對話紀錄。預設沿用既有對話;需要乾淨脈絡時由參數顯式開啟,並在執行前於主控台警示。

## PositionalBinding=$false

實測發現:`nb-digest.ps1 -Notebook X -Question $q1, $q2` 會讓 `$q2` 被 positional 綁到 `$OutDir`,腳本靜默把輸出寫到以問題文字為名的路徑。

四支腳本全部加上 `[CmdletBinding(PositionalBinding=$false)]`,參數一律具名。傳錯改為**大聲失敗**,消滅整類靜默錯誤。

## References 精簡渲染

`notebooklm ask --json` 的 references 含 `cited_text` —— 也就是**來源全文**。原本直接 `ConvertTo-Json` 倒進摘要,等於把要省的 token 又塞回去。

改為以 `source list --json` 建立 `source_id → title` 對映,渲染成 `- [N] <檔名> -- <120 字截斷片段>`。單筆引用從 ~700 bytes 降到 ~150 bytes。
