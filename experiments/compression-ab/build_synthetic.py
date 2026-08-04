#!/usr/bin/env python3
"""실크기 threshold 실험용 합성 코퍼스.

축소 재현은 protect_last_n·prune·tail 채우기가 얽혀 계속 깨졌다.
그래서 실크기로 가되, 코퍼스가 모자란 것만 해결한다 —
고유도 1.00인 세션들을 이어붙여 313K+ 토큰을 만든다.

배치가 중요하다:
  맨 앞  vault(7c4e67)  → P2("반드시 기억"하라 한 볼트 위치)가 압축을 전부 겪는다
  맨 뒤  rivian(441de6) → P1/P4/P5(현재 작업·지적·미해결)가 마지막 기준으로 유효

서로 다른 주제가 이어져 대화로는 부자연스럽지만,
압축 알고리즘 비교에는 문제되지 않는다 — 두 설정에 같은 입력이 들어간다.
"""
import json, os, sqlite3, sys
sys.path.insert(0, os.path.expanduser("~/.hermes/hermes-agent"))
from agent.model_metadata import estimate_messages_tokens_rough as est

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from extract_corpus import load_session

ORDER = [
    ("20260723_202332_7c4e67", "vault — P2 출처(맨 앞이라 압축을 전부 겪음)"),
    ("20260516_075502_2f6190", "패딩"),
    ("20260707_080410_f22599", "패딩"),
    ("20260702_084129_1bebdc", "패딩"),
    ("20260720_230652_441de6", "rivian — P1/P4/P5 출처(맨 뒤)"),
]

msgs, marks, total = [], [], 0
for sid, note in ORDER:
    part = load_session(sid)
    if not part:
        print(f"  ⚠️ {sid} 비어 있음", file=sys.stderr); continue
    start = total
    msgs += part
    total = est(msgs)
    marks.append({"session": sid, "note": note, "messages": len(part),
                  "token_start": start, "token_end": total})
    print(f"  {sid}  {len(part):3d}개 / 누적 {total:,} 토큰   {note}")

os.makedirs("corpus", exist_ok=True)
json.dump({"synthetic": True, "sections": marks, "total_tokens_rough": total,
           "generations": [msgs]},
          open("corpus/synth.json", "w"), ensure_ascii=False, indent=1)
print(f"\n총 {len(msgs)}개 메시지 / {total:,} 토큰")
print(f"T35 4회 압축 필요 234,883 → {'✓' if total >= 234883 else '✗ 부족'}")
print(f"T65 4회 압축 필요 313,526 → {'✓' if total >= 313526 else '✗ 부족'}")
