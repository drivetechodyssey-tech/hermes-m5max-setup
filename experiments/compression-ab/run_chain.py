#!/usr/bin/env python3
"""세대 연쇄 압축 A/B 러너.

조건 A: 메인 8bit가 직접 압축 (auxiliary.compression.provider: auto)
조건 B: gemma-4-12B-it-OptiQ-4bit가 압축

핵심 설계 — 왜 이런 구조인가

1) hermes의 실제 압축 코드를 그대로 쓴다.
   ContextCompressor._generate_summary()가 12개 섹션 템플릿을 만들고,
   2세대부터는 PREVIOUS SUMMARY를 넣은 iterative-update 프롬프트로 바뀐다
   (context_compressor.py:1345). 프롬프트를 우리가 다시 쓰면 그 분기를 놓친다.

2) config.yaml은 건드리지 않는다.
   agent.context_compressor가 call_llm을 모듈 레벨로 import하므로
   그 이름만 바꿔치기하면 프롬프트 생성 로직은 원본 그대로 두고
   실제 호출 모델만 통제할 수 있다.

3) 최종 답변은 양쪽 다 메인 8bit가 만든다.
   그래야 "답변자 능력 차이"가 아니라 "요약 품질 차이"만 남는다.

4) 조건 B는 모델 스왑을 동반한다.
   8bit(35GB) + gemma(8.8GB)를 동시에 올리면 ceiling 56GB에서
   프리필 헤드룸이 남지 않아 oMLX prefill memory guard가 요청을 거부한다.
   그래서 압축 전후로 명시적으로 언로드/로드한다. 그 시간도 조건 B의 비용이다.
   (실측: 8bit 언로드 0.3s + gemma 로드 5.8s + 8bit 재로드 9.0s ≈ 15s)
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

HERMES = os.path.expanduser("~/.hermes/hermes-agent")
sys.path.insert(0, HERMES)

BASE = "http://127.0.0.1:8000"
MAIN = "Qwen3.6-35B-A3B-8bit"
AUX = "gemma-4-12B-it-OptiQ-4bit"

# 컨텍스트는 운영값 그대로 둔다.
#
# 초안은 32768로 낮춰 압축 발동점을 11.5K로 만들려 했으나 두 군데서 막혔다:
#   1) threshold_tokens는 MINIMUM_CONTEXT_LENGTH(64,000) 하한에 걸려 안 내려간다
#   2) 더 나쁜 건 max_summary_tokens = min(context × 0.05, 12000)이라
#      요약 예산이 12,000 → 1,638로 쪼그라든다
#
# 요약 예산은 budget = clamp(입력토큰 × 0.20, 2000, max_summary_tokens)인데,
# 예산이 하한 2,000에 눌리면 두 모델이 똑같이 짓눌려 차이가 드러나지 않는다.
# 그래서 컨텍스트는 운영값으로 두고 세대 크기만 줄여 시간을 아낀다.
#   트랙1: 세대 20K rough → 예산 약 2,500~4,000
#   트랙2: 세대 55K rough → 예산 약 8,000~12,000 (운영과 동일 대역)
CTX = 262144
THRESHOLD = 0.35
TARGET_RATIO = 0.35


# ─────────────────────────────────────────────────────────────
# oMLX 직접 호출 (call_llm 대체용)
# ─────────────────────────────────────────────────────────────

class _Msg:
    def __init__(self, content):
        self.content = content


class _Choice:
    def __init__(self, content, finish):
        self.message = _Msg(content)
        self.finish_reason = finish


class _Resp:
    """call_llm 반환값 호환 껍데기 — .choices[0].message.content만 쓰인다."""
    def __init__(self, content, finish, usage):
        self.choices = [_Choice(content, finish)]
        self.usage = usage


def raw_chat(model, messages, max_tokens=2048, timeout=1800, thinking=None):
    body = {"model": model, "messages": messages, "max_tokens": max_tokens}
    if thinking is not None:
        # oMLX는 chat_template_kwargs를 요청 본문 최상위에서만 읽는다.
        # extra_body로 한 겹 감싸면 통째로 무시한다 (1단계에서 실측).
        body["chat_template_kwargs"] = {"enable_thinking": thinking}
    req = urllib.request.Request(
        f"{BASE}/v1/chat/completions", data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "Authorization": "Bearer local"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        d = json.load(r)
    u = d.get("usage", {}) or {}
    ch = d["choices"][0]
    return {
        "content": ch["message"].get("content") or "",
        "finish": ch.get("finish_reason"),
        "elapsed": time.time() - t0,
        "prompt_tokens": u.get("prompt_tokens", 0),
        "completion_tokens": u.get("completion_tokens", 0),
        "cached": u.get("prompt_tokens_details", {}).get("cached_tokens", 0),
    }


def model_op(model, op):
    """load / unload. 소요 시간을 돌려준다."""
    req = urllib.request.Request(f"{BASE}/v1/models/{model}/{op}", data=b"{}",
                                 headers={"Content-Type": "application/json"})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=900):
            pass
    except urllib.error.HTTPError as e:
        e.read()
    return time.time() - t0


def loaded_models():
    with urllib.request.urlopen(f"{BASE}/v1/models/status", timeout=30) as r:
        d = json.load(r)
    return [m["id"] for m in d["models"] if m["loaded"]]


def ensure_only(model):
    """model만 상주하도록 만든다. 소요 시간 반환."""
    spent = 0.0
    for m in loaded_models():
        if m != model:
            spent += model_op(m, "unload")
    if model not in loaded_models():
        spent += model_op(model, "load")
    return spent


# ─────────────────────────────────────────────────────────────
# 세대 연쇄
# ─────────────────────────────────────────────────────────────

def make_compressor(context_length, max_summary_tokens=None):
    """압축기 인스턴스.

    max_summary_tokens를 주면 코드 상수 천장(_SUMMARY_TOKENS_CEILING = 12,000)을
    덮어쓴다. 요약 예산은 clamp(압축대상 × 0.20, 2000, max_summary_tokens)이므로
    천장을 충분히 크게 잡으면 항상 압축대상의 1/5 = **압축률 5:1이 보장**된다.

    threshold 비교 실험에서 이게 필요하다. threshold를 0.65로 올리면
    압축 대상이 110,755가 되는데 예산이 12,000에 묶이면 9.2:1이 되어버려
    "압축률은 동일하게"라는 조건이 깨진다.
    """
    from agent.context_compressor import ContextCompressor
    c = ContextCompressor(
        model=MAIN,
        threshold_percent=THRESHOLD,
        summary_target_ratio=TARGET_RATIO,
        base_url=f"{BASE}/v1",
        api_key="local",
        provider="omlx",
        api_mode="chat_completions",
        config_context_length=context_length,
        quiet_mode=True,
    )
    if max_summary_tokens:
        c.max_summary_tokens = max_summary_tokens
    return c


def run_chain(corpus, condition, context_length, log, max_summary_tokens=None):
    """한 조건으로 G1..Gn을 연쇄 압축한다.

    조건:
      A     — 메인 8bit, thinking 켜짐 (현행 provider: auto 그대로)
      A-off — 메인 8bit, thinking 꺼짐 (auxiliary.compression.extra_body로 설정 가능)
      B     — gemma-4-12B

    A는 스모크에서 4세대 중 2세대가 finish=length였고 thinking이 요약 자리를
    잡아먹는 게 확인됐다. A-off는 그게 설정 하나로 해결되는 문제인지 가른다.

    조건 B는 압축 때마다 gemma로 스왑했다가 되돌린다.
    그 시간을 세대별로 기록한다 — A 계열은 0이다.
    """
    import agent.context_compressor as cc

    summary_model = AUX if condition == "B" else MAIN
    thinking = False if condition == "A-off" else None
    comp = make_compressor(context_length, max_summary_tokens)

    calls = []          # monkeypatch가 채우는 실제 호출 기록

    def fake_call_llm(**kw):
        r = raw_chat(summary_model, kw["messages"],
                     max_tokens=kw.get("max_tokens") or 2048,
                     timeout=kw.get("timeout") or 1800,
                     thinking=thinking)
        calls.append(r)
        return _Resp(r["content"], r["finish"], r)

    original = cc.call_llm
    cc.call_llm = fake_call_llm
    try:
        gens = []
        for gi, turns in enumerate(corpus["generations"], 1):
            swap_s = 0.0
            if condition == "B":
                swap_s += ensure_only(AUX)

            calls.clear()
            t0 = time.time()
            try:
                summary = comp._generate_summary(turns)
                err = None
            except Exception as e:                       # noqa: BLE001
                summary, err = None, f"{type(e).__name__}: {e}"
            compress_s = time.time() - t0

            if condition == "B":
                swap_s += ensure_only(MAIN)

            call = calls[-1] if calls else {}
            rec = {
                "generation": gi,
                "summary": summary,
                "error": err,
                "compress_s": compress_s,
                "swap_s": swap_s,
                "total_s": compress_s + swap_s,
                "prompt_tokens": call.get("prompt_tokens", 0),
                "completion_tokens": call.get("completion_tokens", 0),
                "cached": call.get("cached", 0),
                "finish": call.get("finish"),
                # 보조 모델이 실패하면 hermes는 조용히 메인으로 넘어간다.
                # 그러면 "gemma를 재는 중"이라고 믿으며 메인을 재게 된다.
                "fell_back": bool(getattr(comp, "_summary_model_fallen_back", False)),
            }
            gens.append(rec)
            log(f"    G{gi}: 압축 {compress_s:6.1f}s"
                + (f" + 스왑 {swap_s:5.1f}s" if swap_s else "")
                + f"  in={rec['prompt_tokens']:,} out={rec['completion_tokens']:,}"
                + (f" cached={rec['cached']:,}" if rec["cached"] else "")
                + (f"  finish={rec['finish']}" if rec["finish"] != "stop" else "")
                + ("  ⚠️폴백" if rec["fell_back"] else "")
                + (f"  ❌{err}" if err else ""))
        return gens
    finally:
        cc.call_llm = original


def ask_probes(summary_text, probes, log, label):
    """요약만 주고 프로브를 묻는다. 답변자는 항상 메인 8bit.

    thinking은 끈다. 프로브는 사실 회상이라 추론이 필요 없고,
    켜두면 답을 내기 전에 max_tokens를 다 써서 finish=length가 된다
    (1단계에서 "1+1은?"에 512토큰을 쓰고도 답을 못 낸 사례).
    """
    out = []
    for p in probes:
        msgs = [{"role": "user", "content":
                 f"아래는 이전 작업의 인수인계 문서다.\n\n"
                 f"===== 인수인계 문서 =====\n{summary_text}\n===== 끝 =====\n\n"
                 f"{p['question'].strip()}"}]
        try:
            r = raw_chat(MAIN, msgs, max_tokens=700, thinking=False)
            out.append({"id": p["id"], "answer": r["content"],
                        "elapsed": r["elapsed"], "finish": r["finish"]})
        except Exception as e:                            # noqa: BLE001
            out.append({"id": p["id"], "answer": "", "error": f"{type(e).__name__}: {e}"})
    log(f"      프로브 {label}: " + " ".join(
        f"{o['id']}={'✓' if o.get('answer') else '✗'}" for o in out))
    return out


def serialize_turns(comp, turns):
    """무압축 ceiling용 — 압축기가 쓰는 것과 같은 직렬화를 재사용한다."""
    return comp._serialize_for_summary(turns)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", nargs="+", default=["vault", "rivian"])
    ap.add_argument("--context-length", type=int, default=CTX)
    ap.add_argument("--conditions", nargs="+", default=["A", "A-off", "B"])
    ap.add_argument("--skip-ceiling", action="store_true")
    ap.add_argument("--max-summary-tokens", type=int, default=None,
                    help="코드 상수 천장 12,000을 덮어쓴다. 크게 잡으면 압축률 5:1 고정")
    ap.add_argument("--out", default="results/track1.json")
    args = ap.parse_args()

    import yaml

    def log(msg):
        print(msg, flush=True)

    results = {"context_length": args.context_length, "runs": {}}
    started = time.time()

    for ci, cname in enumerate(args.corpus):
        corpus = json.load(open(f"corpus/{cname}.json"))
        probes = yaml.safe_load(open(f"probes/{cname}.yaml"))["probes"]
        results["runs"][cname] = {}

        # 세대 연쇄는 조건 안에서 순차일 수밖에 없다(G2는 G1의 요약을 입력으로 쓴다).
        # 그래서 조건 단위로는 교대할 수 없고, 대신 코퍼스마다 순서를 뒤집어
        # "항상 뒤에 도는 조건이 발열/드리프트로 불리해지는" 편향을 상쇄한다.
        order = list(args.conditions) if ci % 2 == 0 else list(reversed(args.conditions))
        log(f"\n{'=' * 66}\n코퍼스 {cname} — {len(corpus['generations'])}세대"
            f"  (조건 순서: {' → '.join(order)})\n{'=' * 66}")

        for cond in order:
            desc = {"A": f"{MAIN} (thinking 켜짐)",
                    "A-off": f"{MAIN} (thinking 꺼짐)",
                    "B": AUX}.get(cond, cond)
            log(f"\n  [조건 {cond}] 요약 모델 = {desc}")
            ensure_only(MAIN)          # 두 조건 모두 메인 상주 상태에서 출발
            gens = run_chain(corpus, cond, args.context_length, log,
                             args.max_summary_tokens)

            # 세대별 프로브 — 열화 곡선을 그리려면 매 세대 물어야 한다
            for rec in gens:
                if rec["summary"]:
                    rec["probes"] = ask_probes(rec["summary"], probes, log,
                                               f"{cond}/G{rec['generation']}")
                else:
                    rec["probes"] = []
            results["runs"][cname][cond] = gens

        # 무압축 상한선 — 비교군이 아니라 척도의 100% 지점.
        # 이게 없으면 "A 62점 B 58점"이 유의미한지 오차인지 알 수 없다.
        if not args.skip_ceiling:
            log("\n  [ceiling] 무압축 원본 전체를 그대로 주고 같은 프로브")
            ensure_only(MAIN)
            comp = make_compressor(args.context_length, args.max_summary_tokens)
            all_turns = [m for g in corpus["generations"] for m in g]
            raw = serialize_turns(comp, all_turns)
            results["runs"][cname]["ceiling"] = [{
                "generation": 0,
                "summary": raw,
                "probes": ask_probes(raw, probes, log, "ceiling"),
            }]

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w") as f:
        json.dump(results, f, ensure_ascii=False, indent=1)
    log(f"\n총 {time.time() - started:.0f}초. 저장: {args.out}")


if __name__ == "__main__":
    main()
