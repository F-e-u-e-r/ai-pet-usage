#!/usr/bin/env python3
# 把 Scripts/claude-statusline-hook.sh 以 base64 重新嵌入
# Sources/UsageCore/StatuslineHookScript.swift(勿手改該檔;改了 hook 之後跑本腳本)。
# 位元組一致性由 usagecore-tests 的 drift 測試把關。
import base64
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
src = (ROOT / "Scripts/claude-statusline-hook.sh").read_bytes()
b64 = base64.b64encode(src).decode()
chunks = [b64[i:i + 96] for i in range(0, len(b64), 96)]
body = " +\n        ".join('"%s"' % c for c in chunks)
out = f'''import Foundation

/// 由 `Scripts/claude-statusline-hook.sh` 生成 —— 勿手改。
/// 再生:python3 Scripts/generate-embedded-hook.py
/// 內容以 base64 嵌入(避免任何 Swift 字串轉義語義);與來源檔的位元組一致性
/// 由 usagecore-tests 的 drift 測試把關(兩個 CI workflow 都會跑)。
public enum StatuslineHookScript {{
    static let base64: String =
        {body}

    /// 完整腳本內容(UTF-8,與 Scripts/claude-statusline-hook.sh 位元組相同)。
    public static var content: Data {{
        Data(base64Encoded: base64)!
    }}
}}
'''
(ROOT / "Sources/UsageCore/StatuslineHookScript.swift").write_text(out)
print(f"regenerated: {len(src)} bytes → {len(chunks)} base64 chunks")
