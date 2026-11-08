#!/usr/bin/env python3
"""1단계-c: 모델 스왑의 실제 비용을 잰다.

메인이 8bit(35GB)면 gemma(8.4GB)와 동시 상주가 어렵다.
oMLX ceiling 56GB에 둘을 올리면 43.4GB가 차서 프리필 헤드룸이 남지 않고,
실제로 prefill memory guard가 요청을 거부했다.

그래서 조건 B(gemma로 압축)는 사실상 스왑을 동반한다:
    8bit 언로드 → gemma 로드 → 압축 → gemma 언로드 → 8bit 재로드

컨텍스트 자체는 사라지지 않는다. LLM API는 stateless이고 hermes가 대화를
프롬프트에 직렬화해 보내므로, 모델이 이전 대화를 본 적 없어도 압축은 된다.
사라지는 건 KV 캐시다. 그래서 여기서 재는 것은:

  1. 언로드/로드 실제 소요 시간 (추정치 0.614 s/GB가 맞는가)
  2. 모델을 내렸다 올린 뒤 프롬프트 캐시가 살아남는가
     — oMLX는 SSD 캐시 185GB에 preserve_mid_system_cache: true다.
       살아남으면 스왑 비용은 로드 시간뿐이고,
       날아가면 재프리필(55K에 45초)까지 얹힌다.
"""
import json
import random
import time
import urllib.error
import urllib.request

BASE = "http://127.0.0.1:8000"
MAIN = "Qwen3.6-35B-A3B-8bit"
AUX = "gemma-4-12B-it-OptiQ-4bit"


def post(path, timeout=600):
    req = urllib.request.Request(f"{BASE}{path}", data=b"{}",
                                 headers={"Content-Type": "application/json"})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return time.time() - t0, r.status, r.read()[:200].decode(errors="replace")
    except urllib.error.HTTPError as e:
        return time.time() - t0, e.code, e.read()[:200].decode(errors="replace")


def status():
    with urllib.request.urlopen(f"{BASE}/v1/models/status", timeout=30) as r:
        d = json.load(r)
    loaded = [m["id"] for m in d["models"] if m["loaded"]]
    return d["current_model_memory"] / 2**30, loaded


def chat(model, content, max_tokens=8, timeout=1800):
    req = urllib.request.Request(
        f"{BASE}/v1/chat/completions",
        data=json.dumps({"model": model,
                         "messages": [{"role": "user", "content": content}],
                         "max_tokens": max_tokens}).encode(),
        headers={"Content-Type": "application/json", "Authorization": "Bearer local"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        d = json.load(r)
    u = d.get("usage", {})
    return (time.time() - t0, u.get("prompt_tokens", 0),
            u.get("prompt_tokens_details", {}).get("cached_tokens", 0))


def show(tag):
    mem, loaded = status()
    print(f"    [{tag}] 사용 {mem:.1f}GB  로드됨: {loaded or '(없음)'}")


def main():
    # 압축 대상과 비슷한 규모의 고정 텍스트. 캐시 생존 여부를 보려면
    # 같은 텍스트를 재사용해야 한다 (다른 측정과 목적이 정반대다).
    r = random.Random(20260803)
    probe_text = "다음 토큰 열을 읽고 OK만 답해라.\n" + \
        " ".join(str(r.randrange(10**6)) for _ in range(4400))  # 약 30K 토큰

    print("=" * 62)
    print("모델 스왑 비용 측정")
    print("=" * 62)
    show("시작")

    print("\n[1] 8bit 첫 프리필 (캐시 없음)")
    el, pt, cached = chat(MAIN, probe_text)
    print(f"    {el:.1f}s  prompt_tokens={pt:,}  cached={cached:,}")
    first = {"elapsed": el, "pt": pt, "cached": cached}

    print("\n[2] 8bit 같은 프롬프트 재요청 (캐시 있어야 정상)")
    el, pt, cached = chat(MAIN, probe_text)
    print(f"    {el:.1f}s  prompt_tokens={pt:,}  cached={cached:,}"
          f"{'  ✓ 캐시 적중' if cached else '  ✗ 캐시 미적중'}")
    warm = {"elapsed": el, "pt": pt, "cached": cached}

    print(f"\n[3] {MAIN} 언로드")
    el, code, body = post(f"/v1/models/{MAIN}/unload")
    print(f"    {el:.1f}s  HTTP {code}  {body[:80]}")
    show("언로드 후")
    unload = el

    print(f"\n[4] {AUX} 로드 (8.8GB → 추정 5.4s)")
    el, code, body = post(f"/v1/models/{AUX}/load")
    print(f"    {el:.1f}s  HTTP {code}")
    show("gemma 로드 후")
    aux_load = el

    print("\n[5] gemma로 같은 규모 프리필 (= 압축 작업 대역)")
    try:
        el, pt, cached = chat(AUX, probe_text)
        print(f"    {el:.1f}s  prompt_tokens={pt:,}  cached={cached:,}")
        aux_prefill = {"elapsed": el, "pt": pt, "cached": cached}
    except urllib.error.HTTPError as e:
        body = e.read().decode()[:200]
        print(f"    실패 HTTP {e.code}: {body}")
        aux_prefill = {"error": body}

    print(f"\n[6] {AUX} 언로드 → {MAIN} 재로드 (36.3GB → 추정 22.3s)")
    el_u, _, _ = post(f"/v1/models/{AUX}/unload")
    el_l, code, _ = post(f"/v1/models/{MAIN}/load")
    print(f"    gemma 언로드 {el_u:.1f}s + 8bit 로드 {el_l:.1f}s = {el_u + el_l:.1f}s")
    show("복귀 후")
    main_reload = el_l

    print("\n[7] 스왑 왕복 후 8bit 같은 프롬프트 — 캐시가 살아남았나")
    el, pt, cached = chat(MAIN, probe_text)
    survived = cached > 0
    print(f"    {el:.1f}s  prompt_tokens={pt:,}  cached={cached:,}")
    print(f"    → 프롬프트 캐시 {'살아남음 ✓' if survived else '날아감 ✗'}")
    after = {"elapsed": el, "pt": pt, "cached": cached}

    print("\n" + "=" * 62)
    print("조건 B(gemma)가 압축 1회당 추가로 지불하는 비용:")
    overhead = unload + aux_load + main_reload
    print(f"  8bit 언로드 {unload:.1f}s + gemma 로드 {aux_load:.1f}s "
          f"+ 8bit 재로드 {main_reload:.1f}s = {overhead:.1f}s")
    if not survived:
        extra = after["elapsed"] - warm["elapsed"]
        print(f"  + 캐시 소실로 인한 재프리필 {extra:.1f}s "
              f"(웜 {warm['elapsed']:.1f}s → 스왑후 {after['elapsed']:.1f}s)")
        print(f"  = 합계 약 {overhead + max(0, extra):.1f}s")
    print("  조건 A(메인 자체 압축)는 이 비용이 0이다.")

    import os
    os.makedirs("results", exist_ok=True)
    with open("results/step1_swap.json", "w") as f:
        json.dump({"first": first, "warm": warm, "unload_s": unload,
                   "aux_load_s": aux_load, "aux_prefill": aux_prefill,
                   "main_reload_s": main_reload, "after_swap": after,
                   "cache_survived": survived, "overhead_s": overhead},
                  f, ensure_ascii=False, indent=2)
    print("\n저장: results/step1_swap.json")


if __name__ == "__main__":
    main()
