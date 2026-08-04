# 압축 보조 모델 A/B 실험 결과

메인 모델이 `Qwen3.6-35B-A3B-8bit`일 때 컨텍스트 압축을 누가 해야 하는가.

실험일 2026-08-03 · 하드웨어 M5 Max 64GB · oMLX ceiling 56GB
설계는 [PLAN.md](PLAN.md), 원시 결과는 `results/track1.json`, `results/track2.json`

---

## 결론

**`auxiliary.compression`을 `provider: auto`로 두고 thinking을 끈다.**

```yaml
auxiliary:
  compression:
    provider: auto        # 메인 모델(8bit) 사용
    model: ''
    extra_body:
      chat_template_kwargs:
        enable_thinking: false
```

gemma-4-12B를 보조 모델로 쓸 이유가 없다. 느리지도 않고, 품질도 낮고,
한국어 대화를 영어로 요약한다.

---

## 세 조건

| 조건 | 요약 모델 | 설명 |
|---|---|---|
| **A** | 8bit, thinking 켜짐 | 현행 `provider: auto` 그대로 |
| **A-off** | 8bit, thinking 꺼짐 | `extra_body`로 thinking만 끔 |
| **B** | gemma-4-12B-it-OptiQ-4bit | 현행 config의 실제 설정 |

최종 답변 생성은 세 조건 모두 메인 8bit가 했다.
그래야 "답변자 능력 차이"가 아니라 "요약 품질 차이"만 남는다.

---

## 1. 속도 — A-off가 2~3배 빠르다

**트랙1** (세대 20K × 4세대, 요약 예산 약 2,500)

| 조건 | vault | rivian | 평균 |
|---|---|---|---|
| A | 365s | 364s | 365s |
| **A-off** | **235s** | **167s** | **201s** |
| B | 355s *(스왑 75s 포함)* | 314s *(스왑 71s 포함)* | 335s |

**트랙2** (세대 45K × 2세대, 요약 예산 9,504 — 운영 12,000에 근접)

| 조건 | 2세대 누적 |
|---|---|
| A | 312s |
| **A-off** | **112s** |
| B | 205s *(스왑 42s 포함)* |

예산이 커질수록 격차가 벌어진다. 트랙2에서 A-off는 A의 **36%**, B의 **55%**다.

**gemma는 빠르지 않다.** 실험 전 전제였던 "작은 모델이니 빠르다"가 틀렸다 —
Qwen3.6-35B-**A3B**는 MoE라 활성 파라미터가 3B고 40레이어 중 10개만 full attention,
gemma-4-12B는 dense 12B다. 같은 30K 프리필에서 **8bit 15.3s vs gemma 25.3s**였다.
여기에 모델 스왑 왕복 약 18s가 압축 1회마다 붙는다.

---

## 2. gemma는 한국어를 버린다 — 단독 탈락 사유

| 조건 | 요약문 한글 비율 |
|---|---|
| A | 0.16 ~ 0.48 |
| A-off | 0.17 ~ 0.37 |
| **B (gemma)** | **0.00 ~ 0.05** |

압축 프롬프트에 명시돼 있다:

> "Write the summary in the same language the user was using in the conversation —
> do not translate or switch to English."

gemma는 트랙1·트랙2 모든 세대에서 이 지시를 무시했다. 예산 크기와 무관하다.

같은 대화, 같은 세대의 `## Active Task` 비교:

**B (gemma)**
```
User asked: "진행해" (Proceed with creating the remaining 19 Wiki files
and updating hot.md, index.md, and log.md).
```

**A-off**
```
hot.md에 21개 링크(`[[page-name]]`)가 걸려있지만 실제 .md 파일이 존재하지 않음.
index.md는 모든 링크 ✅, log.md 세션 1 기록만 있음.
현재 생성된 Wiki 파일로 hot.md/index.md/log.md를 갱신해야 함.
```

A-off 쪽은 그대로 작업을 이어받을 수 있는 상태 기술이다.
gemma는 "무엇을 할지"는 적었지만 **"지금 무엇이 깨져 있는지"**를 담지 못했다.

요약은 `/compress` 후 사용자에게도 보이는 문서다.
읽을 수 없는 언어로 쓰이면 압축의 목적 하나가 통째로 사라진다.

---

## 3. thinking 켜짐(현행 auto)의 구조적 문제

조건 A에서만 나타난 것들 (전체 10세대 기준):

| 증상 | 발생 | 의미 |
|---|---|---|
| `finish=length` | **4회** | 요약이 잘렸다 |
| 섹션 붕괴 (11개 → 3~6개) | 2회 | 템플릿을 못 채웠다 |
| 한자 혼입 | 3세대 (2~3자) | 한국어에 중국어 토큰 누출 |
| thinking 누출 | 2건 | 요약 자리에 자기 생각을 씀 |

실제로 잘린 출력의 끝부분:

```
...most recent unfulfilled input verbatim". User said "진행해" in response to
the assistant's question about proceeding with Wiki generation. I'll phrase it as:
```

요약을 쓰다 말고 "이 섹션을 어떻게 쓸까" 자문하는 내용이 그대로 나왔고
거기서 max_tokens에 걸렸다. A-off와 B는 이 증상이 0회다.

---

## 4. 정보 보존 — `Completed Actions` 항목 수 추이

2세대부터 압축은 iterative-update 프롬프트로 바뀌어
"PRESERVE all existing information"과 "continue numbering"을 요구한다
(`context_compressor.py:1345`). 그러니 항목 수는 세대마다 **늘어야** 정상이고,
줄면 이전 세대를 잊고 있다는 뜻이다.

| 조건 | vault (G1→G4) | rivian (G1→G4) |
|---|---|---|
| A | 8 → **0** → 12 → 11 | 8 → 5 → 10 → 11 |
| **A-off** | 11 → 20 → 35 → **45** | 11 → 17 → 21 → 26 |
| B | 6 → 11 → 22 → 31 | 5 → 12 → 19 → 24 |

A는 vault G2에서 **항목이 0으로 붕괴**했다(`finish=length`로 잘린 세대다).
A-off와 B는 안정적으로 누적한다.

파일 경로 보존 (vault 원본 고유 경로 321개 중, G1→G4):

| A | A-off | B |
|---|---|---|
| 7 → 1 → 1 → 3 | 9 → 15 → 24 → **34** | 6 → 10 → 11 → 14 |

---

## 5. 프로브 정답률 — A와 A-off를 가르지 못한다

무압축(ceiling)을 100% 기준점으로 둔 상대값이다.

| | A | A-off | B |
|---|---|---|---|
| 트랙1 vault 최종세대 | 64% | 55% | **45%** |
| 트랙1 rivian 최종세대 | 69% | 46% | 54% |
| 트랙2 최종세대 | 73% | 64% | **45%** |
| 트랙1 4세대 평균 | 63.9 | 66.2 | 57.1 |

**정직하게 말하면 프로브는 A와 A-off의 우열을 가리지 못했다.**
세대별 요동이 크고(A는 75→58→50→58), 프로브 5문항 × 코퍼스 2건 × 반복 1회라
표본이 작다. 최종세대만 보면 A가 높지만 4세대 평균은 A-off가 높다 — 노이즈 범위다.

**B는 세 측정 중 두 번에서 최하위**이고 평균도 최하다.

그래서 A와 A-off의 판정은 프로브가 아니라 **일관되게 측정된 지표**가 한다:
속도(2~3배), 잘림(4회 vs 0회), 섹션 붕괴(2회 vs 0회), 한자 혼입(3세대 vs 0),
항목·경로 보존(A-off 우위).

---

## 6. 판정 규칙 대조

PLAN 7장에서 실행 전에 못 박은 규칙에 그대로 대입한다.

| 규칙 | 판정 |
|---|---|
| **gemma 채택** — 4세대 누적이 A의 절반 이하 **AND** 종합 점수 A의 90% 이상 | ❌ 335s vs 365s(절반 아님), 프로브 최하 |
| **auto 채택** — 위 미달, 또는 B에서 언어 문제 발생 | ✅ 둘 다 해당 (한글 비율 0.00) |
| **둘 다 탈락** — ceiling 대비 60% 미만 | 해당 없음 (A 64~73%, A-off 55~64%) |

→ **auto 채택.** 그 안에서 A vs A-off는 A-off.

---

## 7. 함께 알아둘 것

**현행 config는 겉보기와 다르게 동작할 수 있다.**
지금 `auxiliary.compression.model: gemma-4-12B-it-OptiQ-4bit`인데,
8bit(35GB)가 상주한 상태에서 gemma를 올리면 프리필 헤드룸이 남지 않아
oMLX 메모리 가드가 요청을 거부한다:

```
Prefill would require ~46.73 GB peak (current 45.21 GB + KV+SDPA 1.53 GB)
but dynamic ceiling is 44.24 GB … only 0 B is reclaimable right now
```

hermes는 이 400을 받으면 `_fallback_to_main_for_compression()`으로
**조용히 메인에 넘긴다**. 즉 "gemma로 압축 중"이라고 믿는 동안
실제로는 메인이 압축하고 실패 왕복 시간까지 얹힌다.
게다가 이 가드는 비결정적이다 — 같은 요청이 실패한 직후 성공했다.
(이 실험에서는 조건 B가 성립하도록 압축 전후로 명시적 언로드/로드를 했다.)

**컨텍스트와 프롬프트 캐시는 모델을 내려도 사라지지 않는다.**
LLM API는 stateless이고 hermes가 대화를 프롬프트에 직렬화해 보내므로,
모델이 이전 대화를 본 적 없어도 압축된다. KV 캐시도 oMLX SSD 캐시(185GB)에
남아 스왑을 넘어 살아남았다(스왑 왕복 후 `cached=28,672`, 15.3s → 4.8s).

**`max_concurrent_requests: 1`** — 압축이 도는 동안 메인은 대기한다.
그래서 압축 시간은 그대로 사용자 대기 시간이다.

---

## 8. 이 실험의 한계

- 코퍼스 2건, 조건당 반복 1회다. 프로브 정답률은 통계적 확신을 주지 못한다.
- 세대 크기가 운영 실제(압축 대상 약 60K)보다 작다.
  트랙1은 20K(예산 2,500), 트랙2는 45K(예산 9,504)다.
  다만 예산이 커질수록 A-off의 우위가 커졌으므로, 실제 60K에서 결론이
  뒤집힐 방향은 아니다.
- 프로브는 사실 회상 위주다. "요약을 근거로 실제 작업을 이어서 수행"하는
  하류 과제는 재지 않았다.
- 한자 혼입은 세대당 2~3자로 적다. 발행 금지 수준인지는 별도 판단이 필요하다.

---

## 부록 — 재현 방법

```bash
cd ~/Projects/hermes-m5max-setup/experiments/compression-ab

python3 pick_corpus.py                        # 코퍼스 후보 스캔 (중복도 검증)
python3 extract_corpus.py --session <id> --name <name> --gen-tokens 20000 --generations 4

~/.hermes/hermes-agent/venv/bin/python run_chain.py --out results/track1.json
~/.hermes/hermes-agent/venv/bin/python score.py --results results/track1.json
```

`run_chain.py`는 `config.yaml`을 건드리지 않는다.
`agent.context_compressor.call_llm`을 monkeypatch해서 프롬프트 생성 로직은
원본 그대로 두고 실제 호출 모델만 통제한다.
