#!/usr/bin/env python3
"""驗證打包價目表(CI 與本機皆可執行)。

用法: python3 Scripts/validate-price-list.py [--base <git-ref>]

閘門:
  schema(兩份價目檔):非空 JSON 陣列;每筆含 providerId/modelId/
    inputPerMillion/outputPerMillion 且價格為非負數;(providerId, modelId) 不重複。
  漂移(僅 generated 檔,需 --base 指向比較基準):
    條目數變化 ≤ 25;同模型 input/output 價格變動 ≤ 5 倍(任一側為 0 則略過)。
    基準中不存在該檔案時略過漂移閘門(首次引入)。
  漂移例外(Scripts/pricing-drift-allowlist.json):真實變價可超過 5× 時的唯一
    合法通道 —— 逐條 (providerId, modelId, field) 暫時放寬到 maxRatio,必附
    expires(含當日)與 reason。例外「套用」一律讀 --base ref 的版本(git show),
    永不讀工作樹副本:同一 PR 不可能先加例外再使用它,例外必須先由 owner 合併進
    baseline 才生效 —— 與「base ref 驗證器副本」同一反繞過哲學。壞檔/壞條目/
    過期 → 忽略該例外(fail-closed 回到嚴格 5×)並印 note。
    另對「工作樹的 allowlist 檔」做純語法 lint(只驗格式,絕不套用):讓改壞
    例外檔的 PR 當場紅,而不是留到下一個 pricing PR 才靜默退回嚴格模式。

exit 0 = 全過;exit 1 = 任一閘門失敗(stdout 印出原因)。
與每日定價 routine 的代理端閘門相同,此處為 PR 上的機械強制版本;
CI 會以 base ref 的腳本副本執行(防止同一 PR 先弱化驗證器再夾帶壞資料)。
另註:動到價目 JSON 的 PR 也會跑 swift-tests —— Swift Codable 解碼是對
資料更嚴格的端對端驗證,公開 repo 的 macOS runner 免費且僅約 30 秒。
"""
import argparse
import json
import math
import os
import subprocess
import sys
from datetime import date

CURATED = "Sources/UsageCore/Resources/model-prices.json"
GENERATED = "Sources/UsageCore/Resources/model-prices-generated.json"
ALLOWLIST = "Scripts/pricing-drift-allowlist.json"
REQUIRED = ("providerId", "modelId", "inputPerMillion", "outputPerMillion")
ALLOWLIST_REQUIRED = ("providerId", "modelId", "field", "maxRatio", "expires", "reason")
DRIFT_FIELDS = ("inputPerMillion", "outputPerMillion")
MAX_COUNT_DELTA = 25
MAX_PRICE_RATIO = 5.0

failures = []


def check(cond, msg):
    if not cond:
        failures.append(msg)


def is_finite_number(v):
    """有限數值(int/float,排除 bool)。巨大整數(如 10**400)在 float() 轉換時
    會拋 OverflowError,一併視為不合法 —— 避免 crash 取代結構化回報(r2 三審同見)。"""
    if not isinstance(v, (int, float)) or isinstance(v, bool):
        return False
    try:
        return math.isfinite(float(v))
    except OverflowError:
        return False


def parse_entries(raw, label):
    try:
        data = json.loads(raw)
    except ValueError as e:  # 統攝 JSONDecodeError/UnicodeDecodeError/digit-limit(r4 NIT 收斂)
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
            # null / bool(Python 的 bool 是 int 子類)/ inf / NaN 都不是合法價格;
            # 缺鍵已由上方回報,這裡只驗證「存在但型別/值不合法」。
            # inf 會被 json 序列化成非標準的 Infinity,Swift 端拒解 → 整份 generated
            # 靜默失效(r2 sol S1;上游若回報 "1e999" 這類值,新模型無 baseline、
            # 漂移閘門管不到,schema 是唯一防線)。
            if key in e:
                v = e[key]
                check(is_finite_number(v) and v >= 0,
                      f"{label}[{i}] ({e.get('modelId', '?')}): {key} 必須為有限非負數,得到 {v!r}")
        # 快取欄位選配,但「在場即需合法」:-1 會靜默少算成本、1e999 → Infinity
        # 一樣毒死 Swift 解碼,而 drift 閘門只看 input/output(r3 luna-ultra MU1)。
        for key in ("cacheReadPerMillion", "cacheWrite5mPerMillion", "cacheWrite1hPerMillion"):
            if key in e:
                v = e[key]
                check(is_finite_number(v) and v >= 0,
                      f"{label}[{i}] ({e.get('modelId', '?')}): {key} 必須為有限非負數,得到 {v!r}")
        ident = (e.get("providerId"), e.get("modelId"))
        if not all(isinstance(x, str) for x in ident):
            # 非字串 id(如 list)會讓集合運算直接 TypeError crash(r2 sol S4,
            # 先於本 PR 存在);缺鍵雙 None 也會誤報「重複」。一律結構化回報。
            check(False, f"{label}[{i}]: providerId/modelId 必須為字串,得到 {ident!r}")
            continue
        check(ident not in seen, f"{label}: 重複條目 {ident}")
        seen.add(ident)
    return data


def git_show(ref, path):
    result = subprocess.run(["git", "show", f"{ref}:{path}"], capture_output=True)
    return result.stdout if result.returncode == 0 else None


def parse_allowlist_entry(e, i, today, on_problem):
    """單條例外的共用解析。合法回傳 ((providerId, modelId, field), maxRatio, expired);
    不合法回傳 None 並經 on_problem 回報。expires 為含當日的 ISO 日期。"""
    if not isinstance(e, dict):
        on_problem(f"allowlist[{i}]: 條目必須是物件")
        return None
    for key in ALLOWLIST_REQUIRED:
        if key not in e:
            on_problem(f"allowlist[{i}] ({e.get('modelId', '?')}): 缺少欄位 {key}")
            return None
    for key in ("providerId", "modelId"):
        if not isinstance(e[key], str) or not e[key].strip():
            on_problem(f"allowlist[{i}] ({e.get('modelId', '?')}): {key} 必須為非空字串,得到 {e[key]!r}")
            return None
    if e["field"] not in DRIFT_FIELDS:
        on_problem(f"allowlist[{i}] ({e.get('modelId', '?')}): field 僅支援 {'/'.join(DRIFT_FIELDS)},得到 {e['field']!r}")
        return None
    ratio = e["maxRatio"]
    # 有限正數:JSON 可寫出 1e999 → inf,inf 會讓 max(5, inf) 形同拆掉上限(r1 NIT#1);
    # 巨大整數經 is_finite_number 結構化拒絕而非 OverflowError crash(r2 三審同見)。
    if not is_finite_number(ratio) or ratio <= 0:
        on_problem(f"allowlist[{i}] ({e.get('modelId', '?')}): maxRatio 必須為有限正數,得到 {ratio!r}")
        return None
    if not isinstance(e["reason"], str) or not e["reason"].strip():
        on_problem(f"allowlist[{i}] ({e.get('modelId', '?')}): reason 必須為非空字串")
        return None
    try:
        expires = date.fromisoformat(e["expires"])
    except (TypeError, ValueError):
        on_problem(f"allowlist[{i}] ({e.get('modelId', '?')}): expires 必須為 ISO 日期,得到 {e['expires']!r}")
        return None
    return (e["providerId"], e["modelId"], e["field"]), float(ratio), today > expires


def load_allowlist(base_ref):
    """讀取「base ref 的」漂移例外表 → {(providerId, modelId, field): maxRatio}。

    反繞過:永不讀工作樹副本 —— 同一 PR 加的例外在該 PR 上不生效,必須先由
    owner 合併進 baseline。任何解析/欄位/日期問題 → 略過該條並印 note
    (fail-closed:退回嚴格 5×,絕不因壞檔放行資料)。"""
    raw = git_show(base_ref, ALLOWLIST)
    if raw is None:
        return {}
    try:
        data = json.loads(raw)
    except ValueError as e:  # 同 parse_entries:統攝三類解析例外(r4 NIT 收斂)
        print(f"note: {ALLOWLIST}@{base_ref} JSON 解析失敗,忽略全部例外(嚴格模式)— {e}")
        return {}
    if not isinstance(data, list):
        print(f"note: {ALLOWLIST}@{base_ref} 必須是陣列,忽略全部例外(嚴格模式)")
        return {}
    today = date.today()
    out = {}
    for i, e in enumerate(data):
        parsed = parse_allowlist_entry(e, i, today, lambda msg: print(f"note: {msg},略過該例外(嚴格模式)"))
        if parsed is None:
            continue
        key, ratio, expired = parsed
        if expired:
            print(f"note: allowlist[{i}] {key} 已於 {e['expires']} 到期,略過(嚴格模式)")
            continue
        if key in out:
            print(f"note: allowlist[{i}] {key} 重複,採較嚴(較小)的 maxRatio")
            out[key] = min(out[key], ratio)
        else:
            out[key] = ratio
    return out


def lint_allowlist_worktree():
    """對工作樹的 allowlist 檔做純語法 lint(絕不套用為例外)。

    例外「套用」只認 base ref;這裡只保證「動到例外檔的 PR」格式錯誤當場紅,
    而不是合併後才在下一個 pricing PR 靜默退回嚴格模式。檔案不存在 → 略過
    (allowlist 是選配)。過期不是 lint 錯誤(時間性,由套用端處理)。"""
    if os.path.islink(ALLOWLIST):
        # 任何 symlink 一律拒:git 對 symlink 儲存的 blob 是「目標路徑字串」,
        # 合併後 git show 讀到的不是內容 → 套用端解析失敗、整條例外通道靜默
        # 退化成嚴格模式(r3 三審同見;懸空與有效目標皆拒,r2 只擋懸空不夠)。
        check(False, "allowlist: 不得為 symlink(git 儲存連結目標路徑,非檔案內容)")
        return
    if not os.path.exists(ALLOWLIST):
        return
    try:
        with open(ALLOWLIST, "rb") as f:
            data = json.loads(f.read())
    except (OSError, ValueError) as e:  # 同上:統攝三類解析例外
        check(False, f"allowlist: 讀取/解析失敗 — {e}")
        return
    if not isinstance(data, list):
        check(False, "allowlist: 必須是陣列")
        return
    today = date.today()
    for i, e in enumerate(data):
        parse_allowlist_entry(e, i, today, lambda msg: check(False, msg))


def drift_gates(old_entries, new_entries, allowlist):
    # 結構防護:schema 已對壞條目結構化回報(該 run 必紅),這裡只保證 drift 不因
    # unhashable id 拋 TypeError、不因 10**400 除法拋 OverflowError —— crash 的
    # traceback 會蓋掉結構化報告(r3 三審同見)。過濾後條目數在紅 run 中略偏無妨。
    def structurally_sane(e):
        return (isinstance(e, dict) and isinstance(e.get("providerId"), str)
                and isinstance(e.get("modelId"), str))
    old_entries = [e for e in old_entries if structurally_sane(e)]
    new_entries = [e for e in new_entries if structurally_sane(e)]
    delta = len(new_entries) - len(old_entries)
    check(abs(delta) <= MAX_COUNT_DELTA,
          f"generated: 條目數變化 {delta:+d} 超過 ±{MAX_COUNT_DELTA}")
    old_by_id = {(e.get("providerId"), e.get("modelId")): e for e in old_entries}
    for e in new_entries:
        old = old_by_id.get((e.get("providerId"), e.get("modelId")))
        if not old:
            continue
        for key in DRIFT_FIELDS:
            a, b = old.get(key), e.get(key)
            if not is_finite_number(a) or not is_finite_number(b):
                continue  # 非有限/巨整數:schema 已回報;除法會 OverflowError,跳過
            if a == 0 or b == 0:
                continue
            ratio = max(a / b, b / a)
            # 例外只放寬、永不收緊(maxRatio < 5 的例外沒有意義,防呆取 max)。
            allowed = allowlist.get((e.get("providerId"), e.get("modelId"), key))
            limit = max(MAX_PRICE_RATIO, allowed) if allowed is not None else MAX_PRICE_RATIO
            if allowed is not None and MAX_PRICE_RATIO < ratio <= limit:
                print(f"note: 漂移例外套用 {e.get('modelId')} {key} {a} → {b}({ratio:.1f}× ≤ {limit}×)")
            check(ratio <= limit,
                  f"generated {e.get('modelId')}: {key} {a} → {b}({ratio:.1f}×)超過 {limit}× 上限")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", help="git ref;提供時對 generated 檔執行漂移閘門")
    args = parser.parse_args()

    with open(CURATED, "rb") as f:
        parse_entries(f.read(), "curated")
    with open(GENERATED, "rb") as f:
        new_entries = parse_entries(f.read(), "generated")
    lint_allowlist_worktree()

    drift_ran = False
    if args.base and new_entries is not None:
        old_raw = git_show(args.base, GENERATED)
        if old_raw is not None:
            old_entries = parse_entries(old_raw, f"generated@{args.base}")
            if old_entries is not None:
                drift_gates(old_entries, new_entries, load_allowlist(args.base))
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
