#!/usr/bin/env python3
"""압축 실험에 쓸 만한 세션을 고른다.

첫 시도(ferrari)에서 걸린 함정: 같은 web_search 결과 4,721자가 20번 반복
저장돼 있어 G2~G4가 정확히 같은 토큰 수로 나왔다. 이런 대화는 압축이
부당하게 쉬워지고(정보 다양성이 없다) "초기 정보가 4세대를 살아남는가"를
측정할 수 없다.

그래서 후보를 고를 때 크기만 보지 않고 아래를 함께 본다:
  - 중복도: 고유 content가 전체의 몇 %인가
  - user 발화 분포: 대화 전반에 걸쳐 있는가 (뒤쪽에도 지시가 있어야
    번복·미해결 프로브를 만들 수 있다)
  - tool 다양성: 한 가지 도구만 반복하는 대화가 아닌가
  - 사실 밀도: 파일 경로·숫자가 얼마나 나오는가 (P2 채점 재료)
"""
import hashlib
import os
import re
import sqlite3

STATE_DB = os.path.expanduser("~/.hermes/state.db")
PATH_RE = re.compile(r"(?:/Users/|~/|\./)[\w./\-]{4,}")
NUM_RE = re.compile(r"\b\d[\d,]{2,}(?:\.\d+)?\b")


def analyze(con, sid):
    rows = con.execute(
        "SELECT role, content, tool_name FROM messages "
        "WHERE session_id=? AND active=1 ORDER BY id", (sid,)
    ).fetchall()
    if len(rows) < 30:
        return None

    contents = [(r[1] or "") for r in rows]
    total_chars = sum(len(c) for c in contents)
    if total_chars < 80_000:
        return None

    # 중복도 — 같은 내용이 반복되면 압축이 부당하게 쉬워진다.
    #
    # 정확 해시로는 못 잡는다. ferrari 세션에서 실제로 겪은 함정:
    # 같은 web_search 결과 4,721자가 반복되는데 끝에 붙은 경고 문구가
    # "returned the same result 28 times" / "29 times"로 숫자만 달라서
    # md5가 전부 달라졌고 고유도가 1.00으로 나왔다.
    # 그래서 숫자와 공백을 지운 뒤 비교한다.
    seen, uniq_chars = set(), 0
    for c in contents:
        if len(c) < 200:
            uniq_chars += len(c)
            continue
        norm = re.sub(r"\s+", "", re.sub(r"\d+", "#", c))
        h = hashlib.md5(norm.encode()).hexdigest()
        if h not in seen:
            seen.add(h)
            uniq_chars += len(c)
    uniq_ratio = uniq_chars / total_chars if total_chars else 0

    # user 발화가 대화 전반에 퍼져 있는가 (뒤쪽 절반에도 있어야 번복 프로브 가능)
    user_pos = [i / len(rows) for i, r in enumerate(rows) if r[0] == "user"]
    late_user = sum(1 for p in user_pos if p > 0.5)

    tools = {r[2] for r in rows if r[2]}
    joined = "\n".join(contents)

    return {
        "sid": sid,
        "msgs": len(rows),
        "ktok": (total_chars + 3) // 4 // 1000,
        "uniq": uniq_ratio,
        "users": len(user_pos),
        "late_users": late_user,
        "tools": len(tools),
        "paths": len(set(PATH_RE.findall(joined))),
        "nums": len(set(NUM_RE.findall(joined))),
    }


def main():
    con = sqlite3.connect(f"file:{STATE_DB}?mode=ro", uri=True)
    sids = [r[0] for r in con.execute(
        "SELECT session_id FROM messages GROUP BY session_id "
        "HAVING SUM(LENGTH(COALESCE(content,''))) > 80000")]

    rows = [a for a in (analyze(con, s) for s in sids) if a]
    con.close()

    # 4세대(46K 토큰)를 뽑으려면 최소 그만큼은 있어야 한다
    rows = [r for r in rows if r["ktok"] >= 50]
    # 고유도 우선, 그다음 사실 밀도
    rows.sort(key=lambda r: (r["uniq"], r["paths"] + r["nums"]), reverse=True)

    print(f"{'세션':24s} {'메시지':>5s} {'K토큰':>6s} {'고유도':>6s} "
          f"{'user':>5s} {'후반':>4s} {'툴종':>4s} {'경로':>5s} {'숫자':>5s}")
    print("-" * 78)
    for r in rows[:14]:
        flag = ""
        if r["uniq"] < 0.6:
            flag = "  ← 중복 많음"
        elif r["late_users"] == 0:
            flag = "  ← 후반 user 없음"
        print(f"{r['sid']:24s} {r['msgs']:5d} {r['ktok']:6d} {r['uniq']:6.2f} "
              f"{r['users']:5d} {r['late_users']:4d} {r['tools']:4d} "
              f"{r['paths']:5d} {r['nums']:5d}{flag}")

    print("\n고유도 = 중복 제거 후 남는 문자 비율. 낮으면 같은 내용이 반복 저장된 것.")
    print("후반 = 대화 후반부(50% 이후)에 나온 user 발화 수. 0이면 번복/미해결 프로브를 못 만든다.")


if __name__ == "__main__":
    main()
