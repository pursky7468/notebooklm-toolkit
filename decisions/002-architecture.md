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

## 為什麼移除 MCP 註冊(2026-08-30)

session 最初裝過 `notebooklm` MCP server,後來移除。決策依據是實測,不是偏好。

**曾經的理由(已證實錯誤)**:以為 MCP 才能做「互動式追問」,CLI 只能單次批次。

**實測推翻**:兩個完全獨立的行程呼叫 `notebooklm ask`,回傳同一個 `conversation_id`,`turn_number` 從 11 遞增到 12,且第二次的問題「你剛剛列的第二種模式,實務上有什麼風險?」被正確解析。

原因:**對話狀態存在 NotebookLM 伺服器端,不在 client 行程裡**。所以 `ask` 預設就會延續對話,與呼叫端是否為同一行程無關 —— 這也是 `--new` 必須是明確 opt-in 的原因。

**移除的實際理由**:

| | MCP | 工具包 + 直接呼叫 CLI |
|---|---|---|
| 對話延續 | 有 | 有(相同機制) |
| 33 個 tool | 打包好 | 直接下 `notebooklm <cmd>` |
| context 成本 | 33 個 tool schema 常駐 | 用到才花 |
| 憑證爭用 | 啟動即 `RotateCookies`,會踩 CLI 憑證 | 無 |

MCP 沒有提供任何工具包做不到的事,卻多兩個成本。其中憑證爭用是實際發生過的事故:診斷 MCP 連線問題時反覆啟動並中途 kill,輪替後的 cookie 未寫回,導致 CLI 憑證一併失效。

**保留的東西**:`notebooklm-py` 套件、`notebooklm.exe`、`notebooklm-mcp.exe`、憑證全部保留。只移除 `~/.claude.json` 的註冊。要恢復隨時可以 `claude mcp add`。
