#!/usr/bin/env python3
"""state.db의 실제 대화를 세대 연쇄 실험용 코퍼스로 뽑는다.

압축 A/B 실험은 같은 원본 구간 G1~G4를 두 조건에 동일하게 먹여야 성립한다.
여기서 하는 일:
  1. 세션 하나를 OpenAI 메시지 형식으로 복원
  2. 목표 토큰 크기로 세대 구간(G1~Gn)으로 분할
  3. tool_calls ↔ tool 응답 쌍이 구간 경계에서 끊기지 않게 정렬

토큰은 hermes가 실제로 쓰는 척도(estimate_tokens_rough = 문자수/4)로 센다.
실제 토크나이저 기준으로는 한국어가 과소추정되지만, 압축 발동 판단 자체가
이 척도를 쓰므로 세대를 나눌 때도 같은 자를 써야 한다.

사용:
    python3 extract_corpus.py --session 20260607_203813_442a5f \
        --name ferrari --gen-tokens 11500 --generations 4
"""
import argparse
import json
import os
import sqlite3
import sys

STATE_DB = os.path.expanduser("~/.hermes/state.db")


def estimate_tokens(text):
    """hermes의 estimate_tokens_rough와 동일 (agent/model_metadata.py:1770)."""
    if not text:
        return 0
    return (len(text) + 3) // 4


def msg_tokens(m):
    total = estimate_tokens(m.get("content") or "")
    if m.get("tool_calls"):
        total += estimate_tokens(json.dumps(m["tool_calls"], ensure_ascii=False))
    return total


def load_session(session_id):
    """state.db 행을 OpenAI chat 메시지로 복원한다."""
    con = sqlite3.connect(f"file:{STATE_DB}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    rows = con.execute(
        "SELECT role, content, tool_call_id, tool_calls, tool_name "
        "FROM messages WHERE session_id=? AND active=1 ORDER BY id", (session_id,)
    ).fetchall()
    con.close()

    messages = []
    for r in rows:
        m = {"role": r["role"], "content": r["content"] or ""}
        if r["tool_calls"]:
            try:
                tc = json.loads(r["tool_calls"])
                if tc:
                    m["tool_calls"] = tc
            except (json.JSONDecodeError, TypeError):
                pass
        if r["tool_call_id"]:
            m["tool_call_id"] = r["tool_call_id"]
        if r["tool_name"]:
            m["name"] = r["tool_name"]
        messages.append(m)
    return messages


def tool_call_ids(m):
    out = set()
    for tc in m.get("tool_calls") or []:
        cid = tc.get("id") if isinstance(tc, dict) else getattr(tc, "id", None)
        if cid:
            out.add(cid)
    return out


def split_generations(messages, gen_tokens, generations):
    """목표 토큰씩 세대 구간으로 자른다.

    경계 규칙: assistant가 tool_calls를 낸 메시지와 그에 대한 tool 응답은
    같은 구간에 둔다. 짝이 갈리면 압축기가 _sanitize_tool_pairs로 한쪽을
    버리게 되어 두 조건에 서로 다른 입력이 들어갈 수 있다.
    """
    gens, cur, cur_tok, pending = [], [], 0, set()

    for m in messages:
        cur.append(m)
        cur_tok += msg_tokens(m)

        if m["role"] == "assistant":
            pending |= tool_call_ids(m)
        elif m["role"] == "tool":
            pending.discard(m.get("tool_call_id"))

        # 예산을 넘었고 열린 tool 호출이 없을 때만 구간을 닫는다
        if cur_tok >= gen_tokens and not pending:
            gens.append(cur)
            cur, cur_tok = [], 0
            if len(gens) >= generations:
                break

    if cur and len(gens) < generations:
        gens.append(cur)
    return gens


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--session", required=True)
    ap.add_argument("--name", required=True, help="코퍼스 이름 (출력 파일명)")
    ap.add_argument("--gen-tokens", type=int, default=11500,
                    help="세대당 목표 토큰. 트랙1(축소)=11500, 트랙2(실크기)=60000")
    ap.add_argument("--generations", type=int, default=4)
    ap.add_argument("--outdir", default="corpus")
    args = ap.parse_args()

    messages = load_session(args.session)
    if not messages:
        print(f"메시지 없음: {args.session}", file=sys.stderr)
        return 1

    total = sum(msg_tokens(m) for m in messages)
    gens = split_generations(messages, args.gen_tokens, args.generations)

    print(f"세션 {args.session}")
    print(f"  전체 {len(messages)}개 메시지 / 약 {total:,} 토큰 (rough)")
    print(f"  세대 {len(gens)}개 (요청 {args.generations}개, 세대당 목표 {args.gen_tokens:,})")
    for i, g in enumerate(gens, 1):
        roles = {}
        for m in g:
            roles[m["role"]] = roles.get(m["role"], 0) + 1
        tk = sum(msg_tokens(m) for m in g)
        print(f"    G{i}: {len(g):3d}개 / {tk:7,} 토큰  {roles}")

    if len(gens) < args.generations:
        print(f"  ⚠️ 세대가 {args.generations}개에 못 미친다 — "
              f"--gen-tokens를 낮추거나 더 긴 세션을 쓸 것", file=sys.stderr)

    os.makedirs(args.outdir, exist_ok=True)
    out = os.path.join(args.outdir, f"{args.name}.json")
    with open(out, "w") as f:
        json.dump({
            "session_id": args.session,
            "gen_tokens_target": args.gen_tokens,
            "total_tokens_rough": total,
            "generations": gens,
        }, f, ensure_ascii=False, indent=1)
    print(f"저장: {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
