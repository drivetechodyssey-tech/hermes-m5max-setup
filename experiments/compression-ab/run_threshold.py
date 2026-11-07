#!/usr/bin/env python3
"""threshold / target_ratio 조합 비교 — compress() 전체를 태운다.

왜 run_chain.py로는 안 되는가
─────────────────────────────
0.35/0.35와 0.65/0.65는 압축 대상이 **완전히 같다**:

    압축대상 = CTX × threshold × (1 − target_ratio)
    0.35 × 0.65 = 0.2275
    0.65 × 0.35 = 0.2275   ← 동일 (59,638 토큰)

요약 예산도 11,927로 같다. 다른 건 tail뿐이다 (32,112 vs 110,755).
run_chain.py는 _generate_summary(압축대상)만 호출하므로 두 설정에
**똑같은 입력**이 들어간다 — 구별 자체가 불가능하다.

그래서 여기서는 실제 대화 흐름을 시뮬레이션한다:
  메시지를 하나씩 쌓다가 → threshold 도달 → compress() 호출 →
  압축된 배열로 계속 → 다음 threshold 도달 → ...

압축 직후의 **컨텍스트 전체(요약 + tail)**를 프로브에 준다.
그래야 tail이 큰 쪽의 이점이 측정된다.

핵심 차이 (계산):
  0.35/0.35 → 압축 후 44,039 중 요약 11,927 = 요약 의존도 27.1%
  0.65/0.65 → 압축 후 122,682 중 요약 11,927 = 요약 의존도  9.7%

축소 재현
─────────
실제 크기로는 코퍼스가 모자란다(0.65/0.65는 첫 압축이 170,393인데
가장 긴 세션이 98K). 그래서 1/SCALE로 줄인다.
threshold_tokens는 MINIMUM_CONTEXT_LENGTH(64,000) 하한에 걸려
생성자로는 못 낮추므로 인스턴스 속성을 직접 세팅한다.
"""
import argparse
import json
import os
import sys
import time
import urllib.request

HERMES = os.path.expanduser("~/.hermes/hermes-agent")
sys.path.insert(0, HERMES)

BASE = "http://127.0.0.1:8000"
MAIN = "Qwen3.6-35B-A3B-8bit"
CTX = 262144
# SCALE = 1 이면 운영 설정 그대로다.
#
# 처음엔 SCALE=4로 축소하려 했으나 계속 다른 데서 깨졌다:
#   - protect_last_n(20)을 안 줄여 압축 대상이 거의 남지 않았고
#     (압축해도 총량이 늘어남: 23,440 → 23,574)
#   - 줄인 뒤에도 tail 예산을 채울 메시지가 부족해
#     T65의 tail 3.4배가 재현되지 않았다(_find_tail_cut_by_tokens는
#     뒤에서부터 메시지를 모아 예산을 채우는 방식이다)
#   - _prune_old_tool_results가 먼저 돌아 tool 결과를 줄이는 것도 겹쳤다
#
# 토큰·메시지 수·prune·tail 채우기가 얽혀 있어 단순 비례 축소가 성립하지 않는다.
# 그래서 실크기로 가고, 모자란 코퍼스는 합성으로 채운다(build_synthetic.py).
SCALE = 1

SETTINGS = {
    "T35": (0.35, 0.35),     # 현행
    "T65": (0.65, 0.65),     # 제안 — 압축대상·예산 동일, tail만 3.4배
}


def raw_chat(model, messages, max_tokens=2048, timeout=1800, thinking=None):
    body = {"model": model, "messages": messages, "max_tokens": max_tokens}
    if thinking is not None:
        body["chat_template_kwargs"] = {"enable_thinking": thinking}
    req = urllib.request.Request(
        f"{BASE}/v1/chat/completions", data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "Authorization": "Bearer local"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        d = json.load(r)
    u = d.get("usage", {}) or {}
    ch = d["choices"][0]
    return {"content": ch["message"].get("content") or "",
            "finish": ch.get("finish_reason"), "elapsed": time.time() - t0,
            "prompt_tokens": u.get("prompt_tokens", 0),
            "completion_tokens": u.get("completion_tokens", 0),
            "cached": u.get("prompt_tokens_details", {}).get("cached_tokens", 0)}


def make_compressor(threshold, target_ratio):
    """축소 스케일로 압축기를 만든다.

    생성자만으로는 안 된다 — threshold_tokens가 MINIMUM_CONTEXT_LENGTH(64,000)
    하한에 걸리고, tail_token_budget과 max_summary_tokens도 거기서 파생되기
    때문이다. 그래서 계산한 값을 인스턴스에 직접 넣는다.

    protect_last_n도 반드시 함께 줄여야 한다. 첫 시도에서 이걸 빠뜨려
    실험 전체가 무효가 됐다 — 토큰만 1/4로 줄이고 "최근 20개 메시지 보호"를
    그대로 두니, 압축 후 메시지가 13~27개만 남는 축소 환경에서는 그중
    20개가 보호되어 압축할 대상이 거의 없었다. 결과적으로 압축을 해도
    총량이 안 줄거나 오히려 늘었고(23,440 → 23,574), 요약 비중도
    목표치(27.1% / 9.7%)와 무관한 2~15%가 나왔다.
    """
    from agent.context_compressor import ContextCompressor
    c = ContextCompressor(
        model=MAIN, threshold_percent=threshold, summary_target_ratio=target_ratio,
        base_url=f"{BASE}/v1", api_key="local", provider="omlx",
        api_mode="chat_completions", config_context_length=CTX, quiet_mode=True,
        protect_first_n=3, protect_last_n=max(3, 20 // SCALE))

    fire_full = int(CTX * threshold)
    c.threshold_tokens = fire_full // SCALE
    c.tail_token_budget = int(fire_full * target_ratio) // SCALE
    # 예산 천장도 같은 비율로 — 실제 운영에서 11,927이므로 축소하면 2,981.
    # 하한 _MIN_SUMMARY_TOKENS(2,000)에 눌리지 않도록 SCALE을 4로 잡았다.
    c.max_summary_tokens = 12000 // SCALE
    return c


def sim_tokens(messages):
    from agent.model_metadata import estimate_messages_tokens_rough
    return estimate_messages_tokens_rough(messages)


def ask_probes(messages, probes, log, label):
    """압축 직후 컨텍스트 전체(요약 + tail)를 주고 묻는다.

    run_chain.py는 요약문만 줬지만, 여기서는 tail이 변수이므로
    실제 모델이 보는 것 그대로를 줘야 한다.
    """
    ctx = []
    for m in messages:
        role = m.get("role", "")
        body = m.get("content") or ""
        if m.get("tool_calls"):
            body += " " + json.dumps(m["tool_calls"], ensure_ascii=False)[:600]
        if body.strip():
            ctx.append(f"[{role}] {body}")
    blob = "\n".join(ctx)

    out = []
    for p in probes:
        msgs = [{"role": "user", "content":
                 f"아래는 진행 중인 작업의 컨텍스트다.\n\n"
                 f"===== 컨텍스트 =====\n{blob}\n===== 끝 =====\n\n"
                 f"{p['question'].strip()}"}]
        try:
            r = raw_chat(MAIN, msgs, max_tokens=700, thinking=False)
            out.append({"id": p["id"], "answer": r["content"],
                        "elapsed": r["elapsed"], "finish": r["finish"],
                        "ctx_tokens": r["prompt_tokens"], "cached": r["cached"]})
        except Exception as e:                            # noqa: BLE001
            out.append({"id": p["id"], "answer": "", "error": f"{type(e).__name__}: {e}"})
    ok = sum(1 for o in out if o.get("answer"))
    log(f"      프로브 {label}: {ok}/{len(out)} 응답  "
        f"(컨텍스트 {out[0].get('ctx_tokens', 0):,} 토큰)")
    return out


def run_setting(all_messages, name, threshold, target_ratio, probes, log):
    """메시지를 하나씩 쌓다가 threshold에 닿으면 compress()를 부른다."""
    import agent.context_compressor as cc

    comp = make_compressor(threshold, target_ratio)
    log(f"\n  [{name}] threshold={threshold} target_ratio={target_ratio}  "
        f"→ 발동 {comp.threshold_tokens:,} / tail {comp.tail_token_budget:,} "
        f"/ 요약상한 {comp.max_summary_tokens:,} / protect_last {comp.protect_last_n}")

    calls = []

    def fake_call_llm(**kw):
        r = raw_chat(MAIN, kw["messages"], max_tokens=kw.get("max_tokens") or 2048,
                     timeout=kw.get("timeout") or 1800, thinking=False)
        calls.append(r)
        return type("R", (), {"choices": [type("C", (), {
            "message": type("M", (), {"content": r["content"]})(),
            "finish_reason": r["finish"]})()]})()

    original = cc.call_llm
    cc.call_llm = fake_call_llm
    events = []
    try:
        messages = []
        for msg in all_messages:
            messages.append(msg)
            tok = sim_tokens(messages)
            # should_compress()를 그대로 쓴다. force=True로 부르면
            # 안티스래싱(_ineffective_compression_count)이 무시되어
            # "압축해도 안 줄어드는데 계속 압축하는" 비현실적 상태가 된다.
            if not comp.should_compress(tok):
                continue

            before = tok
            calls.clear()
            t0 = time.time()
            try:
                messages = comp.compress(messages, current_tokens=tok)
                err = None
            except Exception as e:                        # noqa: BLE001
                err = f"{type(e).__name__}: {e}"
            el = time.time() - t0
            after = sim_tokens(messages)
            call = calls[-1] if calls else {}

            # 압축 후 컨텍스트에서 '요약'이 차지하는 비율 — 이 실험의 핵심 지표
            summary_tokens = 0
            for m in messages:
                if comp._is_context_summary_content(m.get("content")):
                    summary_tokens = (len(m["content"]) + 3) // 4
                    break

            rec = {"n": len(events) + 1, "before": before, "after": after,
                   "compress_s": el, "error": err,
                   "summary_tokens": summary_tokens,
                   "summary_share": summary_tokens / after if after else 0,
                   "msgs_after": len(messages),
                   "prompt_tokens": call.get("prompt_tokens", 0),
                   "completion_tokens": call.get("completion_tokens", 0),
                   "cached": call.get("cached", 0), "finish": call.get("finish")}
            log(f"    압축#{rec['n']}: {before:,} → {after:,} "
                f"({el:.1f}s)  요약 {summary_tokens:,}토큰 = "
                f"{rec['summary_share'] * 100:.1f}%  메시지 {len(messages)}개"
                + (f"  finish={rec['finish']}" if rec["finish"] != "stop" else "")
                + (f"  ❌{err}" if err else ""))
            rec["probes"] = ask_probes(messages, probes, log, f"{name}/#{rec['n']}")
            events.append(rec)
        return events
    finally:
        cc.call_llm = original


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", nargs="+", default=["vault", "rivian"])
    ap.add_argument("--settings", nargs="+", default=["T35", "T65"])
    ap.add_argument("--out", default="results/threshold.json")
    args = ap.parse_args()

    import yaml

    def log(m):
        print(m, flush=True)

    results = {"scale": SCALE, "runs": {}}
    t0 = time.time()
    for ci, cname in enumerate(args.corpus):
        with open(f"corpus/{cname}.json") as f:
            corpus = json.load(f)
        with open(f"probes/{cname}.yaml") as f:
            probes = yaml.safe_load(f)["probes"]
        all_messages = [m for g in corpus["generations"] for m in g]
        results["runs"][cname] = {}

        # 코퍼스마다 설정 순서를 뒤집어 순서 효과를 상쇄한다
        order = list(args.settings) if ci % 2 == 0 else list(reversed(args.settings))
        log(f"\n{'=' * 68}\n코퍼스 {cname} — 메시지 {len(all_messages)}개 / "
            f"{sim_tokens(all_messages):,} 토큰  (순서: {' → '.join(order)})\n{'=' * 68}")

        for name in order:
            th, tr = SETTINGS[name]
            results["runs"][cname][name] = run_setting(
                all_messages, name, th, tr, probes, log)

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w") as f:
        json.dump(results, f, ensure_ascii=False, indent=1)
    log(f"\n총 {time.time() - t0:.0f}초. 저장: {args.out}")


if __name__ == "__main__":
    main()
