#!/usr/bin/env python3
"""從 OpenRouter 公開 API 產生完整模型價目表。

    python3 Scripts/update-price-list.py            # 抓取並重寫 generated 價目
    python3 Scripts/update-price-list.py cached.json  # 用已下載的回應檔

輸出:Sources/UsageCore/Resources/model-prices-generated.json
規則:
  - 只收有本地 adapter(或已規劃 adapter)的供應商:
      anthropic → claude-code、openai → codex、google → antigravity、x-ai → grok-code
  - 價格為 OpenRouter 回報的每 token 美元 × 1e6(對 anthropic/openai 即官方牌價)。
  - Claude 模型 id 把 '.' 正規化為 '-' 並加 '*' 前綴比對(本地紀錄常帶日期後綴);
    其他供應商一律精確比對,避免 pro/mini 變體誤配。
  - Anthropic 缺 1h 快取寫入價時,依官方 2× input 規則推導(來源欄註明 derived)。
  - 手動維護的 model-prices.json 永遠優先;此檔只補長尾。
"""
import json
import sys
import urllib.request
from datetime import date
from pathlib import Path

VENDOR_TO_PROVIDER = {
    "anthropic": "claude-code",
    "openai": "codex",
    "google": "antigravity",
    "x-ai": "grok-code",
}

OUT = Path(__file__).resolve().parent.parent / "Sources/UsageCore/Resources/model-prices-generated.json"


def fetch():
    if len(sys.argv) > 1:
        return json.load(open(sys.argv[1]))["data"]
    req = urllib.request.Request(
        "https://openrouter.ai/api/v1/models",
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)["data"]


def per_million(pricing, key):
    raw = pricing.get(key)
    if raw in (None, "", "0"):
        return None
    value = float(raw) * 1_000_000
    return round(value, 6) if value > 0 else None


def main():
    today = date.today().isoformat()
    entries = []
    for model in fetch():
        slug = model.get("id", "")
        vendor, _, model_slug = slug.partition("/")
        provider = VENDOR_TO_PROVIDER.get(vendor)
        if not provider or not model_slug or ":" in model_slug:
            continue  # 略過未支援供應商與 :free/:extended 之類變體

        pricing = model.get("pricing", {})
        input_pm = per_million(pricing, "prompt")
        output_pm = per_million(pricing, "completion")
        if input_pm is None or output_pm is None:
            continue  # 免費/嵌入類條目對成本計算無意義

        cache_read = per_million(pricing, "input_cache_read")
        write_5m = per_million(pricing, "input_cache_write")
        write_1h = per_million(pricing, "input_cache_write_1h")
        source = f"openrouter.ai/api/v1/models (generated {today})"
        if provider == "claude-code":
            model_id = model_slug.replace(".", "-") + "*"
            if write_5m is not None and write_1h is None:
                write_1h = round(input_pm * 2, 6)  # Anthropic 官方 1h 快取寫入 = 2× input
                source += "; 1h cache write derived as 2x input"
        else:
            model_id = model_slug

        entry = {
            "providerId": provider,
            "modelId": model_id,
            "displayName": model.get("name", model_slug).split(": ", 1)[-1],
            "inputPerMillion": input_pm,
            "outputPerMillion": output_pm,
            "currency": "USD",
            "effectiveFrom": today,
            "source": source,
            "userOverride": False,
        }
        if cache_read is not None:
            entry["cacheReadPerMillion"] = cache_read
        if write_5m is not None:
            entry["cacheWrite5mPerMillion"] = write_5m
        if write_1h is not None:
            entry["cacheWrite1hPerMillion"] = write_1h
        entries.append(entry)

    entries.sort(key=lambda e: (e["providerId"], e["modelId"]))
    OUT.write_text(json.dumps(entries, indent=2, ensure_ascii=False) + "\n")
    by_provider = {}
    for e in entries:
        by_provider[e["providerId"]] = by_provider.get(e["providerId"], 0) + 1
    print(f"wrote {len(entries)} entries to {OUT}")
    print(by_provider)


if __name__ == "__main__":
    main()
