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
  - 價格欄位全數未變的條目沿用舊檔的 effectiveFrom/source:沒變價的日子重跑
    產生零 diff(daily workflow 因此不開空 PR),有變價時 diff 只剩真實變動,
    effectiveFrom 也才真正代表「這組價格自何時生效」。
"""
import json
import math
import os
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


def per_million(pricing, key, slug):
    raw = pricing.get(key)
    # 上游文件化語意:無此價/免費(真正的 absent)。數字 0/0.0 也是合法免費編碼
    # (bool 除外 —— Python bool 是 int 子類)。注意 JSON 數字形 -0.0(未加引號的
    # -1e-400 underflow)滿足 raw == 0 卻是負零 —— 必須在這裡就驗符號,否則會在
    # copysign 檢查之前被當免費放行(r6 sol MUST-FIX;字串形已擋、數字形補齊)。
    if raw is None or raw in ("", "0") or (
            isinstance(raw, (int, float)) and not isinstance(raw, bool)
            and raw == 0 and math.copysign(1.0, raw) > 0):
        return None
    # malformed ≠ absent(r4 三審同見):bool 會被 float() 強轉成 $1,000,000/M、
    # "1e999" 會變 inf(json 再序列化成毒死 Swift 的 Infinity)、垃圾字串裸拋
    # ValueError、10**400 拋 OverflowError。任何「在場但不合法」的值一律結構化
    # 致命 —— 寧可整次 refresh 紅,也不靜默丟欄位、丟模型、或讓 derived 值頂替。
    if isinstance(raw, bool):
        sys.exit(f"malformed pricing: {slug} {key}={raw!r}(bool 不是價格)")
    try:
        value = float(raw) * 1_000_000
    except (TypeError, ValueError, OverflowError):
        sys.exit(f"malformed pricing: {slug} {key}={raw!r}(無法解析為有限數值)")
    if not math.isfinite(value):
        sys.exit(f"malformed pricing: {slug} {key}={raw!r}(非有限)")
    # 符號用 copysign 判:"-1e-400" 會 underflow 成 -0.0,而 -0.0 < 0 為 False,
    # 直接比較會讓 malformed 負值靜默變 absent(r5 sol MUST-FIX)。
    if math.copysign(1.0, value) < 0:
        sys.exit(f"malformed pricing: {slug} {key}={raw!r}(負值/負零)")
    # 免費編碼已在最前面 return;走到這裡的 0 只能是正 underflow("1e-400")→ 同屬 malformed。
    if value == 0:
        sys.exit(f"malformed pricing: {slug} {key}={raw!r}(underflow 至 0)")
    return round(value, 6)


# effectiveFrom/source 沿用判斷所比對的價格欄位(全部相等才算「未變價」)。
PRICE_FIELDS = ("inputPerMillion", "outputPerMillion", "cacheReadPerMillion",
                "cacheWrite5mPerMillion", "cacheWrite1hPerMillion")


def load_price_map(path):
    """價目 JSON → {(providerId, modelId): entry};讀不到/形狀不對就當空。

    except ValueError 而非 JSONDecodeError:統攝 UnicodeDecodeError(壞 UTF-8)
    與 3.11+ int 位數上限的裸 ValueError(r4 三審 NIT 收斂;皆為其子類/同類)。"""
    try:
        prev = json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return {}
    if not isinstance(prev, list):
        return {}
    return {(e.get("providerId"), e.get("modelId")): e
            for e in prev if isinstance(e, dict)}


def load_previous():
    """現有 generated 檔(daily workflow 會先以 evergreen 分支內容 seed 此檔)。"""
    return load_price_map(OUT)


def load_main_snapshot():
    """main 基準快照(選配,env PRICING_MAIN_SNAPSHOT 指路徑)。

    用途:上游把價格「徹回到 main 現值」時,provenance 必須正規化回 main 的
    effectiveFrom/source,讓輸出與 main 位元組一致 → workflow 的 changed=false
    才會成立、stale evergreen PR 才關得掉;否則 seed 自分支的比較基準會把徹回
    當成變價、留下 metadata-only 的殭屍 PR(r3 三審同見)。未設 env(本機、
    無分支情境)→ 空映射,行為退回單一 previous 基準。"""
    path = os.environ.get("PRICING_MAIN_SNAPSHOT")
    return load_price_map(path) if path else {}


def main():
    today = date.today().isoformat()
    previous = load_previous()
    main_map = load_main_snapshot()
    entries = []
    for model in fetch():
        slug = model.get("id", "")
        vendor, _, model_slug = slug.partition("/")
        provider = VENDOR_TO_PROVIDER.get(vendor)
        if not provider or not model_slug or ":" in model_slug:
            continue  # 略過未支援供應商與 :free/:extended 之類變體

        pricing = model.get("pricing", {})
        input_pm = per_million(pricing, "prompt", slug)
        output_pm = per_million(pricing, "completion", slug)
        if input_pm is None or output_pm is None:
            continue  # 免費/嵌入類條目對成本計算無意義

        cache_read = per_million(pricing, "input_cache_read", slug)
        write_5m = per_million(pricing, "input_cache_write", slug)
        write_1h = per_million(pricing, "input_cache_write_1h", slug)
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
        # provenance 沿用優先序(缺鍵雙邊皆為 None 視為相等):
        #   1. 價格 == main 快照 → 取 main 的 effectiveFrom/source(徹回歸零 diff,
        #      見 load_main_snapshot 說明);
        #   2. 價格 == previous(evergreen 分支/本機舊檔)→ 保留首見日;
        #   3. 皆不合 → 今天(真變價)。
        key_id = (entry["providerId"], entry["modelId"])
        main_e = main_map.get(key_id)
        old = previous.get(key_id)
        if main_e and all(main_e.get(f) == entry.get(f) for f in PRICE_FIELDS):
            entry["effectiveFrom"] = main_e.get("effectiveFrom", entry["effectiveFrom"])
            entry["source"] = main_e.get("source", entry["source"])
        elif old and all(old.get(f) == entry.get(f) for f in PRICE_FIELDS):
            entry["effectiveFrom"] = old.get("effectiveFrom", entry["effectiveFrom"])
            entry["source"] = old.get("source", entry["source"])
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
