#!/usr/bin/env python3
"""1단계: 8bit 메인과 gemma 보조 모델이 실사용 가능한지 확인한다.

압축 A/B 실험을 시작하기 전에 확인할 것:
  - 두 모델이 실제로 응답하는가
  - 한국어가 깨지지 않는가 (4bit 다국어 모델의 알려진 결함)
  - 긴 프롬프트를 받는가, 프리필이 얼마나 걸리는가
  - 프롬프트 캐시에 오염되지 않았는가 (cached_tokens 확인)

프롬프트 캐시 오염을 피하려고 매 측정마다 고유 텍스트를 만든다.
"""
import json
import sys
import time
import urllib.request

BASE = "http://127.0.0.1:8000/v1"
MAIN = "Qwen3.6-35B-A3B-8bit"
AUX = "gemma-4-12B-it-OptiQ-4bit"


def call(model, messages, max_tokens=256, extra_body=None, timeout=1800):
    body = {"model": model, "messages": messages, "max_tokens": max_tokens}
    if extra_body:
        body.update(extra_body)
    req = urllib.request.Request(
        f"{BASE}/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "Authorization": "Bearer local"},
    )
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        d = json.load(r)
    return d, time.time() - t0


def unique_filler(target_tokens, seed):
    """캐시에 걸리지 않는 고유 텍스트를 만든다.

    같은 텍스트를 재사용하면 91,385 tok/s 같은 물리적으로 불가능한 값이 나온다.
    seed를 섞어 매번 다른 토큰 열을 만든다.
    """
    words = []
    x = seed * 7919 + 13
    for i in range(target_tokens):
        x = (x * 1103515245 + 12345) & 0x7FFFFFFF
        words.append(f"{x % 100000}-{chr(97 + x % 26)}{chr(97 + (x >> 7) % 26)}")
    return " ".join(words)


def cache_flag(usage):
    c = (usage or {}).get("prompt_tokens_details", {}).get("cached_tokens", 0)
    return f"  ⚠️ CACHED={c} (측정 무효)" if c else ""


def check_korean(model, label):
    print(f"\n--- {label}: 한국어 응답 ---")
    d, el = call(model, [{"role": "user", "content":
        "다음 문장을 한국어로 한 문장으로 요약해라. 다른 말은 붙이지 마라.\n"
        "'게이트웨이는 launchd로 실행되므로 PATH가 최소값만 갖는다. "
        "따라서 homebrew 도구를 쓰는 스크립트는 내부에서 PATH를 직접 지정해야 한다.'"}],
        max_tokens=512)
    txt = d["choices"][0]["message"]["content"]
    fin = d["choices"][0].get("finish_reason")
    # 4bit 다국어 모델은 한국어 출력에 중국어·베트남어 문자가 섞이는 이력이 있다.
    hangul = sum(1 for ch in txt if "가" <= ch <= "힣")
    cjk = sum(1 for ch in txt if "一" <= ch <= "鿿")
    print(f"시간 {el:.1f}s  finish={fin}  한글 {hangul}자  한자 {cjk}자{cache_flag(d.get('usage'))}")
    print("응답:", repr(txt[:300]))
    if cjk:
        print(f"  ⚠️ 한자 {cjk}자 혼입 — 판정 규칙상 단독 탈락 사유")
    return {"elapsed": el, "hangul": hangul, "cjk": cjk, "finish": fin, "text": txt}


def check_prefill(model, label, tokens, seed):
    print(f"\n--- {label}: 프리필 {tokens:,} 토큰 ---")
    filler = unique_filler(tokens, seed)
    try:
        d, el = call(model, [{"role": "user", "content":
            f"아래는 무의미한 토큰 열이다. 읽고 'OK'만 답해라.\n\n{filler}"}],
            max_tokens=16)
    except Exception as e:
        print(f"  실패: {type(e).__name__} {e}")
        return None
    u = d.get("usage", {})
    pt = u.get("prompt_tokens", 0)
    print(f"시간 {el:.1f}s  prompt_tokens={pt:,}  "
          f"프리필 {pt / el:,.0f} tok/s{cache_flag(u)}")
    return {"elapsed": el, "prompt_tokens": pt,
            "cached": u.get("prompt_tokens_details", {}).get("cached_tokens", 0)}


def main():
    results = {}
    print("=" * 60)
    print("1단계 — 모델 실사용 확인")
    print("=" * 60)

    for model, label in ((MAIN, "MAIN 8bit"), (AUX, "AUX gemma-12B")):
        results[label] = {"korean": check_korean(model, label)}

    # 프리필은 두 모델을 교대로 잰다. 순차로 A→B를 재면 두 번째가 항상 느리다
    # (발열/드리프트). 여기서는 규모 확인이 목적이라 1회씩이지만 순서를 섞는다.
    seed = int(time.time())
    for i, size in enumerate((4000, 16000)):
        for model, label in ((AUX, "AUX gemma-12B"), (MAIN, "MAIN 8bit")):
            r = check_prefill(model, label, size, seed + i * 17 + hash(label) % 97)
            results[label][f"prefill_{size}"] = r

    out = "results/step1_probe.json"
    import os
    os.makedirs("results", exist_ok=True)
    with open(out, "w") as f:
        json.dump(results, f, ensure_ascii=False, indent=2)
    print(f"\n저장: {out}")


if __name__ == "__main__":
    sys.exit(main())
