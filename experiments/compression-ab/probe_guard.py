#!/usr/bin/env python3
"""1단계-b: 실제 압축 대상 크기에서 gemma가 돌아가는지 확인한다.

배경 — oMLX의 prefill memory guard가 같은 요청을 실패시켰다가 성공시킨다.
8bit(35GB)와 gemma(8.4GB)가 동시 상주하면 프리필 헤드룸이 거의 남지 않는데,
가드의 dynamic ceiling은 시스템의 다른 앱 상황에 따라 움직이기 때문이다.

가드에 걸리면 hermes는 400을 받고 _fallback_to_main_for_compression()으로
조용히 메인 모델에 넘긴다. 즉 "gemma로 압축 중"이라고 믿는 동안 실제로는
메인이 압축하고, 실패 왕복 시간까지 얹힌다.

여기서 재는 것: 실제 압축 대상 크기(약 60K 토큰)에서 gemma의 성공률.
대부분 튕기면 조건 B는 본 실험 이전에 이미 탈락이다.

전제: 8bit가 상주한 상태를 유지한다. 그게 실사용 조건이다.
"""
import json
import random
import re
import statistics
import time
import urllib.error
import urllib.request

BASE = "http://127.0.0.1:8000/v1"
MAIN = "Qwen3.6-35B-A3B-8bit"
AUX = "gemma-4-12B-it-OptiQ-4bit"
TRIALS = 5
TARGET_TOKENS = 60_000  # 운영 압축 대상 규모


def filler(word_count, seed):
    """캐시에 걸리지 않는 고유 텍스트. 매 시도 seed를 바꾼다."""
    r = random.Random(seed)
    return " ".join(str(r.randrange(10**6)) for _ in range(word_count))


def call(model, content, max_tokens=16):
    req = urllib.request.Request(
        f"{BASE}/chat/completions",
        data=json.dumps({
            "model": model,
            "messages": [{"role": "user", "content": content}],
            "max_tokens": max_tokens,
        }).encode(),
        headers={"Content-Type": "application/json", "Authorization": "Bearer local"},
    )
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=1800) as r:
            d = json.load(r)
        u = d.get("usage", {})
        return {
            "ok": True, "elapsed": time.time() - t0,
            "prompt_tokens": u.get("prompt_tokens", 0),
            "cached": u.get("prompt_tokens_details", {}).get("cached_tokens", 0),
        }
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        m = re.search(r"~([\d.]+) GB peak \(current ([\d.]+) GB.*?ceiling is ([\d.]+) GB", body)
        return {
            "ok": False, "elapsed": time.time() - t0, "status": e.code,
            "guard": bool(m),
            "peak": float(m.group(1)) if m else None,
            "current": float(m.group(2)) if m else None,
            "ceiling": float(m.group(3)) if m else None,
            "body": body[:200],
        }
    except Exception as e:
        return {"ok": False, "elapsed": time.time() - t0,
                "status": type(e).__name__, "guard": False, "body": str(e)[:200]}


def main():
    # 숫자 토큰 하나가 대략 6.9토큰으로 잡혔다 (13,790 tok / 2,000 단어).
    words = int(TARGET_TOKENS / 6.9)
    seed = int(time.time())
    results = {"main": [], "aux": []}

    print(f"압축 대상 규모 {TARGET_TOKENS:,} 토큰 (filler {words:,} 단어) × {TRIALS}회")
    print("두 모델을 교대로 돌린다 — 순차로 몰면 두 번째가 발열/드리프트로 불리해진다.\n")

    for i in range(TRIALS):
        for model, key in ((AUX, "aux"), (MAIN, "main")):
            r = call(model, "다음 토큰 열을 읽고 OK만 답해라.\n" + filler(words, seed + i * 101 + len(key)))
            results[key].append(r)
            if r["ok"]:
                warn = "  ⚠️ CACHED (무효)" if r["cached"] else ""
                print(f"[{i+1}/{TRIALS}] {key:4s} 성공  {r['elapsed']:6.1f}s  "
                      f"pt={r['prompt_tokens']:,}{warn}")
            elif r.get("guard"):
                print(f"[{i+1}/{TRIALS}] {key:4s} 가드거부 {r['elapsed']:5.1f}s  "
                      f"peak {r['peak']}GB > ceiling {r['ceiling']}GB (current {r['current']}GB)")
            else:
                print(f"[{i+1}/{TRIALS}] {key:4s} 실패  {r.get('status')}  {r.get('body','')[:90]}")

    print("\n" + "=" * 58)
    for key, label in (("aux", "gemma-12B (조건 B)"), ("main", "8bit 메인 (조건 A)")):
        rs = results[key]
        ok = [r for r in rs if r["ok"]]
        guard = [r for r in rs if not r["ok"] and r.get("guard")]
        line = f"{label:22s} 성공 {len(ok)}/{len(rs)}"
        if guard:
            line += f"  가드거부 {len(guard)}"
        if ok:
            times = [r["elapsed"] for r in ok]
            line += f"  중앙값 {statistics.median(times):.1f}s"
            if len(times) > 1:
                line += f" (범위 {min(times):.1f}~{max(times):.1f})"
        print(line)

    import os
    os.makedirs("results", exist_ok=True)
    with open("results/step1_guard.json", "w") as f:
        json.dump(results, f, ensure_ascii=False, indent=2)
    print("\n저장: results/step1_guard.json")


if __name__ == "__main__":
    main()
