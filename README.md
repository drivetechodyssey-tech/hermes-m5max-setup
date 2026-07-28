# Hermes Agent & Local AI Setup Guide (Apple Silicon M5 Max)

> 내 깃 저장소 — Hermes Agent와 로컬 LLM을 Apple Silicon Mac에 셋업하는 가이드 + 자동화 스크립트 모음입니다.

> **2026-07-27 갱신** — 백엔드가 Ollama에서 **oMLX**로 바뀌었습니다. 이전 판의 Ollama 기준 설명과 KV 캐시 표는 현재 구성과 맞지 않아 전면 수정했습니다.

## 📋 목차

- [환경 개요](#환경-개요)
- [Quick Start](#quick-start)
- [구성 파일](#구성-파일)
- [설정값 참고](#설정값-참고)
- [메모리 계산](#메모리-계산)
- [스킬 관리와 curator](#스킬-관리와-curator)
- [메모리 시뮬레이터](#메모리-시뮬레이터)
- [자가 진단](#자가-진단)
- [트러블슈팅](#트러블슈팅)
- [모델 선택 가이드](#모델-선택-가이드)

---

## 환경 개요

| 항목 | 내용 |
|------|------|
| 기기 | MacBook Pro M5 Max |
| 메모리 | 64GB 통합 메모리 |
| 추론 백엔드 | **oMLX** (`127.0.0.1:8000`) |
| 에이전트 | Hermes Agent (게이트웨이 `127.0.0.1:8642`, 대시보드 `:9120`) |
| 메인 모델 | `Qwen3.6-35B-A3B-4bit` (MLX, 19GB) |
| 컨텍스트 | 131,072 토큰 |

> Ollama는 더 이상 상시 구성이 아닙니다. `~/.hermes/config.yaml`의 `providers.omlx`가 유일한 주 백엔드입니다.

---

## Quick Start

### 1. oMLX 서버 실행

Homebrew 서비스로 관리되므로 백그라운드로 뜹니다.

```bash
omlx start
```

살아 있는지 확인:

```bash
curl -s http://127.0.0.1:8000/v1/models | python3 -m json.tool
```

### 2. Hermes Agent 실행

```bash
hermes
```

PATH가 안 걸려 있으면:

```bash
export PATH="$HOME/.hermes/hermes-agent/venv/bin:$PATH"
```

> **Hermes가 먹통이면 십중팔구 oMLX가 안 떠 있는 것입니다.** `config.yaml`의 `providers.omlx.base_url`이 `127.0.0.1:8000`을 가리키는데 그 포트가 비어 있으면 모든 호출이 조용히 실패합니다. 위 `curl`부터 확인하세요.

---

## 구성 파일

```
hermes-m5max-setup/
├── README.md                   # 이 파일
├── setup.sh                    # 자동 설치 스크립트
├── macbook-m5-simulator.html   # 메모리 시뮬레이터 (단일 HTML)
└── docs/
    └── wellgroomed.md          # 상세 가이드
```

### 핵심 설정 파일

| 경로 | 역할 |
|------|------|
| `~/.hermes/config.yaml` | Hermes 전체 설정 |
| `~/.hermes/.env` | 비밀값 (권한 600, 여기에만 둔다) |
| `~/.hermes/skills/` | 스킬 라이브러리 |
| `~/.hermes/skills/.usage.json` | 스킬 사용 통계 + 핀 상태 |
| `~/.hermes/state.db` | 세션·메시지 저장소 (SQLite) |

> **비밀값은 `config.yaml`에 직접 쓰지 않습니다.** MCP 설정을 포함해 문자열 값에서 `${VAR}` 치환이 지원되고, `~/.hermes/.env`가 시작 시 로드됩니다.
>
> ```yaml
> mcp_servers:
>   figma:
>     headers:
>       Authorization: "Bearer ${FIGMA_TOKEN}"
> ```

---

## 설정값 참고

### 현재 적용값 (config.yaml)

```yaml
model:
  default: Qwen3.6-35B-A3B-4bit
  max_tokens: 131072
  provider: omlx

agent:
  max_turns: 60            # 기본값 90. 10은 너무 낮아 작업이 중간에 끊긴다

tool_output:
  max_bytes: 16000         # 툴 1회 출력 ≈ 4K 토큰 상한
  max_lines: 600
file_read_max_chars: 40000 # 파일 1회 읽기 ≈ 10K 토큰 상한

compression:
  enabled: true
  threshold: 0.7           # 컨텍스트 70%에서 자동 압축
  target_ratio: 0.35
  protect_last_n: 20

streaming:
  enabled: true            # 로컬 모델은 켜야 체감 대기가 짧다

sessions:
  auto_prune: true
  retention_days: 90
```

### 왜 `tool_output.max_bytes`가 중요한가

대화 내용의 대부분은 사람이 쓴 글이 아니라 **툴 출력**입니다. 실측하면 30일간
툴 메시지 9.1MB / assistant 0.7MB / user 0.7MB — 툴이 86%입니다.

상한이 없으면 `read_file` 한 번에 25K 토큰, `session_search` 한 번에 18K 토큰이
컨텍스트로 들어와 압축이 계속 돌고 세션이 조기 종료됩니다. 위 상한이 이걸 막습니다.

---

## 메모리 계산

KV 캐시 공식:

### 이 모델에는 일반적인 KV 공식이 통하지 않는다

흔히 쓰는 공식은 **모든 레이어가 full attention**이라고 가정합니다.

```
KV (GB) = 2 × 컨텍스트 × 레이어 수 × KV헤드 수 × 헤드차원 × (비트수/8) / 1GB
```

Qwen3.6은 **하이브리드 어텐션**이라 이 가정이 깨집니다. `config.json`을 보면:

```
full_attention_interval: 4
layer_types: [linear, linear, linear, full, linear, linear, linear, full, ...]
num_hidden_layers: 40   →   full_attention은 10개뿐
```

나머지 30개는 `linear_attention`(Mamba 계열)으로 **시퀀스 길이와 무관하게 상태 크기가
고정**입니다. 컨텍스트에 비례해 자라는 건 10개 레이어뿐이므로, 위 공식을 40레이어로
계산하면 **4배 과대추정**됩니다.

### 실측 (4bit, 가중치 19GB)

| 컨텍스트 | 이론 KV (10 full 레이어) | 관측 RSS |
|---------|------------------------|---------|
| 대기 | — | 19.9 GB |
| 89K | ~1.8 GB | 20.6 GB |
| **178K** | ~3.6 GB | **20.1 GB (변화 없음)** |

178K 토큰을 처리하는 동안에도 프로세스 메모리가 사실상 늘지 않았습니다.
**64GB에서 이 모델의 메모리는 어떤 컨텍스트에서도 제약이 아닙니다.**

### 진짜 제약은 프리필 시간

메모리가 아니라 시간이 컨텍스트 상한을 결정합니다. 캐시 미적중 시 실측:

| 프롬프트 | 프리필 시간 | 속도 |
|---------|-----------|------|
| 7K | 1.7s | 4,167 tok/s |
| 28K | 11.9s | 2,393 tok/s |
| 57K | 31.3s | 1,819 tok/s |
| 89K | 53.5s | 1,662 tok/s |
| **178K** | **279.7s (4분 40초)** | 636 tok/s |

토큰이 2배면 시간은 5배입니다(어텐션의 제곱 비용). 따라서 컨텍스트 상한은
**"메모리에 맞는가"가 아니라 "그 길이를 다시 읽는 데 몇 분을 쓸 것인가"**로 정합니다.

> ⚠️ **이전 판 정정** — 예전 README는 131K를 "63GB, 위험"으로 표기했습니다.
> 38GB짜리 `mxfp8` 기준인 데다 하이브리드 어텐션을 반영하지 않은 값입니다.

### 권장 설정: 상한은 열고, 압축 발동점은 고정

`compression.threshold`는 **컨텍스트 상한에 대한 비율**이라 상한을 올리면 압축 발동점도
같이 밀려납니다 (`context_compressor.py`).

```
threshold_tokens = context_length × threshold
target_tokens    = threshold_tokens × target_ratio
```

그래서 상한만 올리면 "183K까지 쌓아두고 매번 4분씩 다시 읽는" 최악이 됩니다.
비율을 함께 낮춰 **발동점을 절대값으로 고정**하세요.

```yaml
model:
  max_tokens: 262144       # 모델 최대치 — 거대한 툴 결과에도 죽지 않는 여유
compression:
  threshold: 0.35          # 262144 × 0.35 = 91.7K 에서 발동 (131072 × 0.7 과 동일)
  target_ratio: 0.35       # → 32.1K 로 압축
```

이러면 평소 동작은 그대로면서 상한만 열립니다.

---

## 스킬 관리와 curator

curator는 주 1회 돌며 오래 안 쓴 스킬을 정리하는 백그라운드 작업입니다.
**동작 방식에 함정이 있으니 반드시 알고 쓰세요.**

### 함정: curator는 사용 횟수를 보지 않는다

판정 기준은 오직 `last_activity_at` 하나입니다 (`agent/curator.py`).
`use_count`는 전혀 반영되지 않습니다. 즉:

> "30회 썼지만 최근 90일간 안 씀" == "0회 쓰고 방치됨"

프로젝트 단위로 몰아 쓰는 패턴(영상 한 편 만들 때만 `comfyui` 집중 사용)에서는
실제로 잘 쓰던 스킬이 통째로 삭제됩니다. 2026년 6~7월에 `comfyui`(31회),
`youtube-content`(26회), `google-workspace`(14회) 등이 이렇게 사라졌습니다.

### 방어: 핀 고정

`pinned: true`인 스킬은 자동 정리 패스에서 건너뛰고, LLM 정리 패스 프롬프트에도
"pinned=yes는 손대지 마라"가 명시돼 있습니다.

```bash
hermes curator pin <스킬이름>
hermes curator status          # 핀·상태 확인
```

### 안전한 curator 설정

```yaml
curator:
  stale_after_days: 120    # 기본 30 → 너무 짧다
  archive_after_days: 365  # 기본 90 → 너무 짧다
  prune_builtins: false    # 번들 스킬은 건드리지 않는다
  backup:
    keep: 12               # 기본 5 = 주1회 × 5주치뿐. 그 이전은 영구 유실
```

### 복구

리포트는 `~/.hermes/skills/.archive/`에서 복구하라고 안내하지만
**그 디렉토리는 실제로 생성되지 않습니다.** 진짜 복구본은 여기 있습니다:

```bash
ls ~/.hermes/skills/.curator_backups/          # 타임스탬프별 스냅샷
tar tzf ~/.hermes/skills/.curator_backups/<날짜>/skills.tar.gz | grep SKILL.md
```

삭제 이력은 `~/.hermes/logs/curator/<날짜>/run.json`의 `pruned_names`,
`consolidated`에서 확인합니다. `consolidated`는 내용이 다른 스킬로 흡수된
것이므로 복구하면 중복이 됩니다 — `pruned`만 되살리세요.

### 프롬프트 다이어트

시스템 프롬프트의 약 75%가 스킬 인덱스입니다. 안 쓰는 스킬은
`skills.disabled`에 넣으면 프롬프트에서 빠집니다 (파일은 그대로 남습니다).

```yaml
skills:
  disabled:
    - axolotl
    - godmode
```

> 다만 기대치를 낮게 잡으세요. 스킬 45개를 비활성화해도 약 1,000 토큰이 줄 뿐입니다.
> 호출당 프리필이 6만 토큰이라면 2% 미만입니다. 진짜 레버는 위의 `tool_output` 상한입니다.

---

## 메모리 시뮬레이터

`macbook-m5-simulator.html` — 컨텍스트 크기별 RAM 사용량을 시각화하는 단일 HTML 도구입니다.
외부 의존성 없이 브라우저에서 바로 열립니다.

### 주요 기능

- **모델 선택**: Qwen3.6 / Gemma4 계열
- **컨텍스트 슬라이더**: 1천~최대 토큰
- **실시간 메모리 계산**: 레이어/KV헤드/헤드차원 기반
- **안전성 표시**: 90%대 노란색 주의, 100% 근접 시 빨간색 경보
- **벤치마크 비교 테이블**: 파라미터·가중치·KV캐시·오버헤드 비교

---

## 자가 진단

```bash
# oMLX 살아 있나 (가장 먼저 확인할 것)
curl -s http://127.0.0.1:8000/v1/models | python3 -m json.tool

# config가 가리키는 모델이 실제로 서빙되는가
python3 -c "import yaml,os; c=yaml.safe_load(open(os.path.expanduser('~/.hermes/config.yaml'))); print(c['model']['default'], '|', c['providers']['omlx']['default_model'])"

# 포트 점유 현황
lsof -nP -iTCP -sTCP:LISTEN | grep -E ':(8000|8642|9120)'

# 압축 설정
python3 -c "import yaml,os; print(yaml.safe_load(open(os.path.expanduser('~/.hermes/config.yaml')))['compression'])"

# 스킬 핀 상태
hermes curator status

# 세션 저장소 크기
hermes sessions stats

# config에 평문 비밀값이 남아 있나 (0이어야 정상)
grep -cE "figd_|AIzaSy|sk-[A-Za-z0-9]{20}|ghp_" ~/.hermes/config.yaml
```

---

## 트러블슈팅

### Hermes가 응답이 없다 / 조용히 실패한다

가장 흔한 원인은 oMLX 미실행입니다.

```bash
omlx start
curl -s http://127.0.0.1:8000/v1/models
```

### config의 모델명이 서버에 없다

`providers.omlx.default_model`이 서버가 서빙하지 않는 이름이면 계속 빗나갑니다.
`/v1/models`가 반환하는 `id`와 **정확히** 같아야 합니다. 예를 들어
`Qwen3.6-35B-A3B-OptiQ-4bit`은 HF 캐시에 디렉토리만 있고 실제 가중치는
받아지지 않은 상태라 서빙되지 않습니다.

### 작업이 자꾸 중간에 멈춘다

`agent.max_turns`를 확인하세요. 기본값은 90인데 10 같은 낮은 값이면
툴 호출 10회에서 그냥 끊깁니다. 실사용 세션의 60%가 툴 호출 10회를 넘깁니다.

### 세션이 자꾸 압축되며 종료된다

툴 출력이 컨텍스트를 밀어내는 경우입니다. `tool_output.max_bytes`와
`file_read_max_chars`를 위의 권장값으로 낮추세요.

### 잘 쓰던 스킬이 사라졌다

curator가 지운 것입니다. 위 [스킬 관리와 curator](#스킬-관리와-curator)의 복구 절차를 따르고,
되살린 뒤에는 반드시 `hermes curator pin`으로 고정하세요.

### MLX 모델 로드 실패

```
ValueError: [quantize] The requested group size 16 is not supported.
```
→ 비표준 양자화입니다. 다른 양자화(4bit/8bit) 버전으로 교체하세요.

---

## 모델 선택 가이드

### 현재 oMLX가 서빙하는 모델

```bash
curl -s http://127.0.0.1:8000/v1/models | python3 -m json.tool
```

| 모델 | 크기 | 용도 |
|------|------|------|
| `Qwen3.6-35B-A3B-4bit` | 19GB | **메인** |
| `Qwen3.6-35B-A3B-8bit` | 35GB | 품질 우선일 때 (단, 아래 참고) |
| `gemma-4-12B-it-OptiQ-4bit` | - | 컨텍스트 압축용 보조 모델 |
| `gemma-4-26b-a4b-it-4bit` | - | 범용 |
| `mlx-community--Llama-3.2-3B-Instruct-4bit` | - | 초경량 |

### 4bit vs 8bit — 실측 비교 (2026-07-27)

| 항목 | 4bit | 8bit | 승자 |
|------|------|------|------|
| 가중치 | 19GB | 35GB | 4bit |
| 생성 속도 | 100.3 tok/s | 85.5 tok/s | 4bit |
| **프리필 50K (캐시 미적중)** | **28.4s** | **41.1s** | **4bit (1.45배)** |
| 최대 컨텍스트 | 262,144 | 131,072 | 4bit |
| tool call 정확도 (6회) | 5/6 | **6/6** | 8bit |
| tool call 총 소요 (6회) | 43.4s | **36.0s** | 8bit |
| reasoning 토큰 낭비 | 많음 (2000토큰 폭주 1회) | 적음 | 8bit |

**결론: 에이전트 용도로는 4bit가 맞습니다.** 8bit가 reasoning을 덜 낭비해 짧은 과제는
더 빨리 끝내지만, Hermes의 실제 워크로드는 **호출당 평균 6만 토큰 프리필**이라
프리필 45% 페널티가 그 이점을 압도합니다. 8bit는 컨텍스트 상한도 절반(131K)입니다.

> ⚠️ 벤치마크할 때 **프롬프트 캐시에 속지 마세요.** 같은 텍스트를 재사용하면
> 4bit가 91,385 tok/s로 측정되는데, 이는 캐시 적중이지 프리필이 아닙니다.
> 반드시 매 측정마다 고유한 텍스트를 쓰고 `usage.prompt_tokens_details.cached_tokens`가
> 0인지 확인하세요.

### gemma-4-26b는?

생성 속도는 비슷하지만(102 tok/s) **8K 프리필이 2.7s로 Qwen의 1.3s보다 2배 느립니다.**
에이전트는 프리필이 지배적인 워크로드라 메인으로는 부적합합니다.

### MLX vs GGUF

- **MLX**: Apple Silicon 최적화, Metal GPU 활용, 약 2배 빠름
- **GGUF**: Ollama 표준 포맷, 범용적
- **nvfp4 / mxfp8**: MLX 전용 포맷 (NVIDIA 전용 아님, 이름만 혼동 주의)

---

더 자세한 내용은 [`docs/wellgroomed.md`](docs/wellgroomed.md)를 참고하세요.
