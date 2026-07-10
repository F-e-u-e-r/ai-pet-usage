#!/usr/bin/env python3
"""驗證打包價目表(CI 與本機皆可執行)。

用法: python3 Scripts/validate-price-list.py [--base <git-ref>]

閘門:
  schema(兩份價目檔):非空 JSON 陣列;每筆含 providerId/modelId/
    inputPerMillion/outputPerMillion 且價格為非負數;(providerId, modelId) 不重複。
  漂移(僅 generated 檔,需 --base 指向比較基準):
    條目數變化 ≤ 25;同模型 input/output 價格變動 ≤ 5 倍(任一側為 0 則略過)。
    基準中不存在該檔案時略過漂移閘門(首次引入)。

exit 0 = 全過;exit 1 = 任一閘門失敗(stdout 印出原因)。
與每日定價 routine 的代理端閘門相同,此處為 PR 上的機械強制版本。
"""
import argparse
import json
import subprocess
import sys

CURATED = "Sources/UsageCore/Resources/model-prices.json"
GENERATED = "Sources/UsageCore/Resources/model-prices-generated.json"
REQUIRED = ("providerId", "modelId", "inputPerMillion", "outputPerMillion")
MAX_COUNT_DELTA = 25
MAX_PRICE_RATIO = 5.0

failures = []


def check(cond, msg):
    if not cond:
        failures.append(msg)


def parse_entries(raw, label):
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        check(False, f"{label}: JSON 解析失敗 — {e}")
        return None
    check(isinstance(data, list) and data, f"{label}: 必須是非空陣列")
    if not isinstance(data, list):
        return None
    seen = set()
    for i, e in enumerate(data):
        if not isinstance(e, dict):
            check(False, f"{label}[{i}]: 條目必須是物件")
            continue
        for key in REQUIRED:
            if key not in e:
                check(False, f"{label}[{i}] ({e.get('modelId', '?')}): 缺少欄位 {key}")
        for key in ("inputPerMillion", "outputPerMillion"):
            v = e.get(key)
            if v is not None:
                check(isinstance(v, (int, float)) and v >= 0,
                      f"{label}[{i}] ({e.get('modelId', '?')}): {key} 必須為非負數,得到 {v!r}")
        ident = (e.get("providerId"), e.get("modelId"))
        check(ident not in seen, f"{label}: 重複條目 {ident}")
        seen.add(ident)
    return data


def git_show(ref, path):
    result = subprocess.run(["git", "show", f"{ref}:{path}"], capture_output=True)
    return result.stdout if result.returncode == 0 else None


def drift_gates(old_entries, new_entries):
    delta = len(new_entries) - len(old_entries)
    check(abs(delta) <= MAX_COUNT_DELTA,
          f"generated: 條目數變化 {delta:+d} 超過 ±{MAX_COUNT_DELTA}")
    old_by_id = {(e.get("providerId"), e.get("modelId")): e for e in old_entries}
    for e in new_entries:
        old = old_by_id.get((e.get("providerId"), e.get("modelId")))
        if not old:
            continue
        for key in ("inputPerMillion", "outputPerMillion"):
            a, b = old.get(key), e.get(key)
            if not isinstance(a, (int, float)) or not isinstance(b, (int, float)):
                continue
            if a == 0 or b == 0:
                continue
            ratio = max(a / b, b / a)
            check(ratio <= MAX_PRICE_RATIO,
                  f"generated {e.get('modelId')}: {key} {a} → {b}({ratio:.1f}×)超過 {MAX_PRICE_RATIO}× 上限")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", help="git ref;提供時對 generated 檔執行漂移閘門")
    args = parser.parse_args()

    with open(CURATED, "rb") as f:
        parse_entries(f.read(), "curated")
    with open(GENERATED, "rb") as f:
        new_entries = parse_entries(f.read(), "generated")

    drift_ran = False
    if args.base and new_entries is not None:
        old_raw = git_show(args.base, GENERATED)
        if old_raw is not None:
            old_entries = parse_entries(old_raw, f"generated@{args.base}")
            if old_entries is not None:
                drift_gates(old_entries, new_entries)
                drift_ran = True
        else:
            print(f"note: {args.base} 無 {GENERATED},略過漂移閘門(首次引入)")

    if failures:
        print(f"FAIL — {len(failures)} 個閘門未通過:")
        for msg in failures:
            print(f"  ✗ {msg}")
        sys.exit(1)
    scope = "schema+drift" if drift_ran else "schema"
    print(f"PASS — 價目表驗證通過({scope};generated {len(new_entries or [])} 條)")


if __name__ == "__main__":
    main()
