#!/usr/bin/env python3
"""세대 연쇄 압축 결과를 채점한다.

두 갈래로 본다.

[자동 지표] 요약문 자체를 기계적으로 검사 — 사람 판단 없음
  섹션 완전성, Completed Actions 항목 수 추이, 파일 경로 보존율,
  한국어 순수성, 비밀값 잔존, 예산 준수, 폴백 발생.
  이 중 Completed Actions 항목 수 추이가 누적 열화의 조기 경보다.
  iterative-update 프롬프트가 "PRESERVE all existing information"과
  "continue numbering"을 요구하므로 세대마다 늘어야 정상이고,
  줄면 모델이 이전 세대 내용을 잊고 있다는 뜻이다.

[프로브 채점] 요약만 보고 답한 내용을 정답표와 대조
  must_include는 동의어 묶음이라 그룹당 하나만 맞으면 통과(부분점수),
  must_not이 걸리면 그 프로브는 0점(환각으로 간주).
  ceiling(무압축) 점수를 100%로 놓고 상대값을 낸다.
"""
import argparse
import json
import re
import sys

SECTIONS = [
    "Active Task", "Goal", "Constraints", "Completed Actions", "Active State",
    "In Progress", "Blocked", "Key Decisions", "Resolved Questions",
    "Pending User Asks", "Relevant Files",
]
SECRET_RE = re.compile(r"\b(sk-[A-Za-z0-9]{16,}|ghp_[A-Za-z0-9]{20,}|"
                       r"AKIA[0-9A-Z]{16}|api[_-]?key\s*[:=]\s*[\"']?[A-Za-z0-9_\-]{20,})")
PATH_RE = re.compile(r"(?:/Users/|~/)[\w./\-]{6,}")
NUMBERED_RE = re.compile(r"^\s*(\d+)\.\s+\S", re.M)


# hermes가 요약 앞에 붙이는 고정 영어 프리픽스(_with_summary_prefix).
# 약 1,000자짜리 안내문이라 모델 출력이 아닌데, 그대로 채점하면
# 한글 비율과 출력 토큰 수를 통째로 왜곡한다.
#
# 직접 잘라내려다 한 번 틀렸다: find("## ")는 프리픽스 본문에 인용된
# "'## Active Task' / '## In Progress'"를 먼저 찾아버려 프리픽스가 남았다.
# hermes 자신의 _strip_summary_prefix를 쓰는 게 정확하다.

# 요약 대신 새어 나온 thinking. 8bit 메인은 reasoning 모델이라
# "이 섹션을 어떻게 쓸까" 자문하는 내용을 그대로 출력에 뱉는다.
THINKING_RE = re.compile(
    r"(Here's a thinking process|I'll phrase it as|Let me (?:think|analyze|write)"
    r"|The user (?:said|wants|is asking)|I need to (?:write|update|preserve)"
    r"|Okay, (?:let|so|the user))", re.I)


def strip_prefix(summary):
    """고정 프리픽스를 걷어내고 모델이 실제로 쓴 부분만 남긴다."""
    if not summary:
        return ""
    import os
    import sys
    sys.path.insert(0, os.path.expanduser("~/.hermes/hermes-agent"))
    from agent.context_compressor import ContextCompressor
    return ContextCompressor._strip_summary_prefix(summary)


def hangul_ratio(text):
    letters = [c for c in text if c.isalpha()]
    if not letters:
        return 0.0
    return sum(1 for c in letters if "가" <= c <= "힣") / len(letters)


def cjk_count(text):
    """비-한글 CJK(한자) 문자 수. 4bit 다국어 모델의 알려진 누출 결함."""
    return sum(1 for c in text if "一" <= c <= "鿿")


def auto_metrics(raw_summary, corpus_paths):
    if not raw_summary:
        return {"missing": True}
    summary = strip_prefix(raw_summary)
    found = [s for s in SECTIONS if f"## {s}" in summary or s in summary]
    nums = [int(n) for n in NUMBERED_RE.findall(summary)]
    sp = set(PATH_RE.findall(summary))
    return {
        "chars": len(summary),
        "approx_tokens": (len(summary) + 3) // 4,
        "thinking_leak": len(THINKING_RE.findall(summary)),
        "sections": len(found),
        "missing_sections": [s for s in SECTIONS if s not in found],
        "completed_items": len(nums),
        "numbering_max": max(nums) if nums else 0,
        "paths": len(sp),
        "path_recall": round(len(sp & corpus_paths) / len(corpus_paths), 3) if corpus_paths else None,
        "hangul": round(hangul_ratio(summary), 3),
        "cjk": cjk_count(summary),
        "secrets": len(SECRET_RE.findall(summary)),
    }


def score_probe(answer, probe):
    """must_include 그룹당 1점씩 부분점수. must_not 걸리면 0점."""
    if not answer:
        return 0.0, "무응답"
    low = answer.lower()
    for bad in probe.get("must_not") or []:
        if bad.lower() in low:
            return 0.0, f"금지어 '{bad}'"
    groups = probe.get("must_include") or []
    if not groups:
        return 1.0, ""
    hit = 0
    missed = []
    for g in groups:
        alts = g if isinstance(g, list) else [g]
        if any(a.lower() in low for a in alts):
            hit += 1
        else:
            missed.append(alts[0])
    return hit / len(groups), ("누락 " + ",".join(missed) if missed else "")


def score_generation(rec, probes_by_id):
    total = 0.0
    maxw = 0.0
    detail = []
    for pa in rec.get("probes") or []:
        p = probes_by_id.get(pa["id"])
        if not p:
            continue
        w = p.get("weight", 1)
        s, note = score_probe(pa.get("answer", ""), p)
        total += s * w
        maxw += w
        detail.append((pa["id"], round(s, 2), note))
    return (total / maxw if maxw else 0.0), detail


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", default="results/track1.json")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    import yaml

    data = json.load(open(args.results))
    print(f"결과 파일: {args.results}  (context_length={data.get('context_length'):,})\n")

    for cname, conds in data["runs"].items():
        probes = yaml.safe_load(open(f"probes/{cname}.yaml"))["probes"]
        by_id = {p["id"]: p for p in probes}
        corpus = json.load(open(f"corpus/{cname}.json"))
        corpus_paths = set()
        for g in corpus["generations"]:
            for m in g:
                corpus_paths |= set(PATH_RE.findall(m.get("content") or ""))

        print("=" * 74)
        print(f"코퍼스 {cname}   (원본 고유 경로 {len(corpus_paths)}개)")
        print("=" * 74)

        ceiling_score = None
        if "ceiling" in conds:
            cs, cd = score_generation(conds["ceiling"][0], by_id)
            ceiling_score = cs
            print(f"\n[ceiling 무압축] 프로브 {cs * 100:5.1f}%   "
                  + " ".join(f"{i}:{v}" for i, v, _ in cd))
            print("  ↑ 이게 100% 기준점이다. 압축 없이도 못 맞히는 건 프로브 문제지 모델 문제가 아니다.")

        labels = {"A": "메인 8bit 자체 압축 (thinking 켜짐 = 현행 auto)",
                  "A-off": "메인 8bit 자체 압축 (thinking 꺼짐)",
                  "B": "gemma-4-12B 압축 (+ 모델 스왑)"}
        for cond in ("A", "A-off", "B"):
            if cond not in conds:
                continue
            label = labels.get(cond, cond)
            print(f"\n[조건 {cond}] {label}")
            print(f"  {'세대':>4s} {'압축s':>7s} {'스왑s':>6s} {'토큰':>6s} "
                  f"{'섹션':>4s} {'항목':>4s} {'경로':>5s} {'한글':>5s} {'한자':>4s} "
                  f"{'프로브':>7s}  비고")
            cum_time = 0.0
            for rec in conds[cond]:
                m = auto_metrics(rec.get("summary"), corpus_paths)
                s, detail = score_generation(rec, by_id)
                cum_time += rec.get("total_s", 0)
                flags = []
                if rec.get("fell_back"):
                    flags.append("⚠️폴백")
                if rec.get("error"):
                    flags.append(f"❌{rec['error'][:40]}")
                if rec.get("cached"):
                    flags.append(f"캐시{rec['cached']:,}")
                if rec.get("finish") and rec["finish"] != "stop":
                    flags.append(f"finish={rec['finish']}")
                if m.get("missing"):
                    print(f"  G{rec['generation']:<3d} {'—':>7s} — 요약 없음  {' '.join(flags)}")
                    continue
                if m["cjk"]:
                    flags.append(f"한자{m['cjk']}자")
                if m["secrets"]:
                    flags.append(f"🚨비밀값{m['secrets']}")
                if m["thinking_leak"]:
                    flags.append(f"thinking누출{m['thinking_leak']}")
                print(f"  G{rec['generation']:<3d} {rec.get('compress_s', 0):7.1f} "
                      f"{rec.get('swap_s', 0):6.1f} {m['approx_tokens']:6,} "
                      f"{m['sections']:4d} {m['completed_items']:4d} "
                      f"{m['paths']:5d} {m['hangul']:5.2f} {m['cjk']:4d} "
                      f"{s * 100:6.1f}%  {' '.join(flags)}")
                if args.verbose:
                    print(f"        {' '.join(f'{i}:{v}{(chr(40) + n + chr(41)) if n else str()}' for i, v, n in detail)}")

            last = conds[cond][-1]
            ls, _ = score_generation(last, by_id)
            rel = f"  (ceiling 대비 {ls / ceiling_score * 100:.0f}%)" if ceiling_score else ""
            print(f"  → 4세대 누적 {cum_time:.0f}s, 최종 프로브 {ls * 100:.1f}%{rel}")

    print("\n항목 = Completed Actions의 번호 매긴 항목 수. "
          "세대가 갈수록 늘어야 정상이고, 줄면 이전 내용을 잊고 있다는 신호다.")


if __name__ == "__main__":
    sys.exit(main())
