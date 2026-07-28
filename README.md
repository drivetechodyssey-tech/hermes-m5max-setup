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

## 보조 모델(auxiliary) 설정

Hermes는 12개 부수 작업(제목 생성, 승인 판단, 압축, 비전, curator 등)에 각각
다른 모델을 지정할 수 있습니다. `provider: auto`는 코드상
**"메인 프로바이더 + 메인 모델"**을 뜻합니다 (`agent/auxiliary_client.py:3063`).

### 로컬은 클라우드와 계산이 다르다

클라우드라면 "가벼운 일엔 싼 모델"이 항상 옳지만, 로컬에서는 모델 스왑 비용을
따져야 합니다. **다만 oMLX는 메모리 상한(56GB) 안에서 여러 모델을 동시 상주시킵니다.**

```bash
curl -s http://127.0.0.1:8000/v1/models/status | python3 -m json.tool | head -5
```

실측: DWQ 20.2GB + gemma-12B 8.8GB + Llama-3B 1.8GB = **3개 동시 상주, 30.7GB**.
첫 호출만 로드 비용(0.19초/GB)을 내고 이후는 전부 `load 0.00s`입니다.
**스왑 스래싱은 일어나지 않으므로 작업별 모델 분리는 안전합니다.**

### 진짜 문제는 모델 크기가 아니라 thinking

메인 모델은 reasoning 모델이라 짧은 작업에서 추론에 예산을 다 씁니다.
"제목을 5단어로" 같은 요청에 **1,500토큰 15초를 쓰고도 답을 못 냅니다**(`finish=length`).

| 설정 | 결과 |
|------|------|
| DWQ, thinking ON, max_tokens=1500 | 15.24s, 1500tok, **답 없음** |
| DWQ, thinking OFF | **0.53s, 8tok, "유튜브 편집 추임새 자동 제거"** |

`auxiliary.<task>.extra_body`가 이걸 제어하는 통로입니다
(`_get_task_extra_body()`가 그대로 전달).

```yaml
auxiliary:
  title_generation:
    extra_body:
      chat_template_kwargs:
        enable_thinking: false
```

### 작업별 배치 원칙

| 부류 | 작업 | 설정 | 이유 |
|------|------|------|------|
| **비전** | `vision` | VLM 모델 **명시 필수** | 메인이 텍스트 전용이면 반드시 분리 |
| **포맷팅** | `title_generation`, `profile_describer` | 메인 + **thinking OFF** | 판단이 필요 없음. 15초 → 0.5초 |
| **판단** | `approval`, `curator`, `triage_specifier`, `kanban_decomposer` | 메인 + **thinking 유지** | 추론을 끄면 오판한다 |
| **요약** | `compression` | `gemma-4-12B-it-OptiQ-4bit` | 빠르고 한국어 깔끔 |

### 모델별 한국어 품질 (실측)

| 모델 | 한국어 출력 | 위험판단 |
|------|-----------|---------|
| DWQ 20GB (thinking OFF) | ✅ 깔끔 | ⚠️ `rm -rf ~/Projects`를 SAFE로 오판 |
| gemma-4-12B 8.8GB | ✅ 깔끔 | 실행마다 흔들림 |
| Llama-3.2-3B 1.8GB | ❌ 외국어 혼입 (`tự động`, `用的`, `उपय`) | 3/3 정답 |

> **Llama-3.2-3B는 한국어 출력 작업에 쓰지 마세요.** 매 실행 베트남어·중국어·데바나가리
> 문자가 섞여 들어옵니다. 속도는 4배 빠르지만(0.11s) 결과물이 못 씁니다.
>
> **위험 판단은 어느 모델도 신뢰할 수 없습니다.** thinking을 끄면 특히 나빠지므로
> `approval`은 추론을 유지하고, 파괴적 명령은 모델 판단에 맡기지 말고
> `command_allowlist` / `approvals.destructive_slash_confirm` 같은 규칙으로 막으세요.

### ⚠️ DWQ로 바꾸면 비전이 사라진다

`Qwen3.6-35B-A3B-4bit-DWQ`는 **비전 가중치가 빠진 텍스트 전용 빌드**입니다.

| | 4bit | 4bit-DWQ |
|---|---|---|
| oMLX engine | `vlm` | `batched` |
| `vision_config` | 있음 | **없음** |
| `preprocessor_config.json` | 있음 | **없음** |

따라서 메인을 DWQ로 쓰려면 **비전은 반드시 VLM으로 따로 지정**해야 합니다.

```yaml
model:
  default: Qwen3.6-35B-A3B-4bit-DWQ    # 텍스트 (tool calling 우수)
auxiliary:
  vision:
    provider: omlx
    model: Qwen3.6-35B-A3B-4bit         # VLM
```

### 현재 설정 확인

```bash
python3 -c "
import yaml,os
a=yaml.safe_load(open(os.path.expanduser('~/.hermes/config.yaml')))['auxiliary']
for k,v in a.items():
    print(f\"{k:<20}{v.get('provider',''):<8}{v.get('model') or '(메인모델)':<30}{v.get('extra_body') or ''}\")"
```

---

## oMLX 성능 기능 — 켜지 말 것 (실측 근거)

oMLX 설정에 꺼져 있는 성능 기능들이 있습니다. 이 구성에서는 **둘 다 켜면 안 됩니다.**

### chunked_prefill → OFF 유지

문서상 이득의 조건이 명확합니다.

> "long prefills are interleaved with decode steps. Reduces TTFT **for concurrent requests**
> at the cost of per-step overhead." (`omlx/settings.py`)

이득은 **동시 요청**에서만 나오는데 `scheduler.max_concurrent_requests: 1`이라 끼워넣을
다른 요청이 없습니다. 교대 측정(ON/OFF 3쌍, 40K 프리필, 캐시 미적중 확인):

| chunked_prefill | 측정값 | 중앙값 |
|-----------------|--------|--------|
| OFF | 25.2, 26.0, 26.3 | **26.0s** |
| ON | 26.7, 26.7, 27.1 | 26.7s |

ON 3개가 모두 OFF 3개보다 높아 범위가 겹치지 않습니다. 차이는 3%로 작지만 일관적이며,
문서의 "per-step overhead" 설명과 일치합니다. **이득 0, 페널티 3%.**

### specprefill → OFF 유지

이건 속도 최적화가 아니라 **정확도를 거래하는 손실 기법**입니다.

```
specprefill_enabled: Enable SpecPrefill (experimental sparse prefill for MoE)
DEFAULT_KEEP_RATE = 0.20   # 프롬프트 토큰의 80%를 버림
DEFAULT_THRESHOLD = 8192   # 8K 넘는 프롬프트마다 발동
```

에이전트 평균 프리필이 6만 토큰이므로 **거의 모든 호출에서 발동**해 대부분을 버립니다.
툴 출력과 코드를 정확히 읽어야 하는 용도에는 부적합합니다. 게다가:

- **draft 모델이 없습니다.** draft는 타깃과 토크나이저를 공유해야 하는데
  Qwen3.6 계열에 8B 이하 모델이 존재하지 않습니다(HF 전수 확인). 후보가 35B뿐이라
  "가벼운 draft로 점수만 매긴다"는 전제가 성립하지 않습니다.
  (기본 설정된 `specprefill_draft_model`은 다운로드조차 안 된 경로입니다.)
- **논문 전제가 다릅니다.** [원 논문](https://arxiv.org/abs/2502.02789)의 7.66× TTFT 개선은
  Llama-3.1-**405B** 기준입니다. Qwen3.6-35B-A3B는 활성 파라미터가 3B인 MoE라
  타깃 자체가 이미 싸서 경제성이 정반대입니다.
- **최적화 대상이 드뭅니다.** Hermes의 프롬프트 캐시 적중률이 93%라
  전체 프리필 자체가 자주 일어나지 않습니다.

## 음성 대화 (TTS / STT)

TUI에서 **Ctrl+B**로 녹음 → 3초 침묵 시 자동 전사 → 에이전트 응답.

`voice.auto_tts: true`(현재 설정)는 **음성 상호작용에만** 적용된다 — 코드로 확인한 동작:

- **CLI/TUI**: 음성 모드 진입 시 응답 낭독이 미리 켜진 상태로 시작할 뿐,
  타이핑 세션은 조용하다 (`cli.py`의 auto_tts 소비처가 음성 모드 진입 경로뿐).
- **메시징 플랫폼**: 음성 메시지에 대한 답장만 낭독하며, 채팅별로
  `/voice on|off` 재정의가 가능하다 (`gateway/platforms/base.py`).
- **낭독 전 가공**: 펜스 코드 블록·URL·마크다운(링크/볼드/헤더/불릿)을 걷어내고
  4,000자에서 자른다. 코드 블록을 소리 내어 읽는 일은 없다 (`hermes_cli/voice.py`).
- **피드백 루프 방지**: TTS 재생 중에는 마이크를 멈춰서 에이전트가
  자기 목소리에 답하는 일을 막는다.

### 현재 구성

| 방향 | 백엔드 | 설정 |
|------|--------|------|
| TTS (말하기) | Edge (무료, 키 불필요) | `ko-KR-SunHiNeural` |
| STT (듣기) | **mlx-whisper** (Metal GPU) | `whisper-large-v3-mlx`, 한국어 고정 |

### STT는 내장 local 대신 mlx-whisper를 쓴다

Hermes 내장 `local` STT는 faster-whisper(CTranslate2) 기반인데, **CTranslate2에는
Metal 경로가 없어 Apple Silicon에서 CPU(int8)로만 돕니다.** 같은 large-v3 가중치를
mlx-whisper로 돌리면 전사 결과는 글자까지 동일한데 15배 빠릅니다 (15.1초 한국어 오디오 실측):

| 백엔드 | 전사 시간 | "커밋을" | "위키링크" |
|--------|----------|---------|-----------|
| faster-whisper base (CPU) | 0.8s | ❌ 커미들 | ❌ 미키링크 |
| faster-whisper large-v3 (CPU) | 8.8s | ✅ | ✅ |
| **mlx-whisper large-v3 (Metal)** | **0.6s 웜 / 1.3s 콜드** | ✅ | ✅ |
| mlx-whisper large-v3-**turbo** | 0.2s | ❌ 커미들 | ✅ |

turbo는 3배 더 빠르지만 base와 같은 부류의 한국어 오인식("커밋을"→"커미들")이 있어
탈락. 음성 명령 용도에서는 오인식이 그대로 잘못된 행동으로 이어지므로 정확도 우선.

연결은 Hermes의 **command STT provider**로 한다 (`stt.providers.<이름>: type: command`):

```yaml
stt:
  provider: mlx_whisper
  providers:
    mlx_whisper:
      type: command
      command: /Users/sungjunmaing/Projects/hermes-m5max-setup/mlx-whisper-stt.sh {input_path} {language}
      language: ko
      format: txt
```

래퍼 스크립트는 [`mlx-whisper-stt.sh`](mlx-whisper-stt.sh) — 전사 결과를 stdout으로
출력하면 Hermes가 transcript로 읽는다. 매 호출이 새 프로세스라 항상 콜드(~2초)지만
CPU 웜(8.8초)보다 4배 빠르다.

> TTS 음성 후보 비교는 `voice-samples/`의 mp3 3종 참고 — 같은 문장(한국어 + 영어
> 식별자 + 숫자)으로 생성했다. 영어 기술 용어가 많으면 `ko-KR-HyunsuMultilingualNeural`
> (다국어)도 고려.

---

## 로그 회전

`config.yaml`의 `logging.max_size_mb` / `backup_count`는 **Python 로거가 쓰는
`agent.log`·`errors.log`에만** 적용됩니다. `gateway.log`와 `gateway.error.log`는
launchd가 `StandardOutPath`/`StandardErrorPath`로 직접 리다이렉트하는 파일이라
그 규칙 밖에 있고 **무한정 자랍니다**(실제로 8.3MB까지 자란 걸 발견).

### mv 로 회전하면 안 되는 이유

게이트웨이 프로세스가 이 파일을 fd로 붙들고 있습니다(`lsof`로 `fd=2u` 확인).
`mv`로 옮기면 프로세스는 **이동된 inode에 계속 쓰므로** 새로 만든 파일은 영영
비어 있고 로그는 옮겨진 파일로 들어갑니다.

그래서 **copytruncate**를 씁니다 — 내용을 복사한 뒤 원본을 제자리에서 비웁니다
(`: > file`). fd가 유지되어 게이트웨이 재시작 없이 회전됩니다.

```bash
# 검증 결과: inode 유지(1730196), 잘린 뒤 offset 0부터 정상 기록,
# 희소파일 아님 → launchd가 O_APPEND로 열기 때문
```

### 구성

| 파일 | 역할 |
|------|------|
| `rotate-logs.sh` | 5MB 초과 시 회전, 3세대 gzip 보관 (config 값과 맞춤) |
| `~/Library/LaunchAgents/ai.hermes.logrotate.plist` | 매일 04:00 실행 (sudo 불필요) |

대상: `gateway.error.log`, `gateway.log`, `desktop.log`, `gui.log`

> macOS 기본 도구인 `newsyslog`는 `/etc/newsyslog.d/`에 써야 해서 sudo가 필요합니다.
> 사용자 레벨 launchd 에이전트로 하면 권한 없이 됩니다.

### 확인 / 수동 실행

```bash
# 지금 바로 회전
~/Projects/hermes-m5max-setup/rotate-logs.sh

# launchd 등록 상태와 마지막 실행 결과
launchctl print gui/$(id -u)/ai.hermes.logrotate | grep -E "runs =|last exit|state ="

# 강제 실행
launchctl kickstart -p gui/$(id -u)/ai.hermes.logrotate

# 해제
launchctl unload ~/Library/LaunchAgents/ai.hermes.logrotate.plist
```

---

### 설정 API 함정

`/admin/api/global-settings`의 스키마는 **평면**입니다. 중첩 형태로 보내면
`{"success":true,"message":"Settings saved successfully."}`를 반환하면서
**아무것도 저장하지 않습니다.**

```bash
# ❌ 조용히 무시됨
curl -X POST .../admin/api/global-settings -d '{"scheduler":{"chunked_prefill":true}}'

# ✅ 평면 형태
curl -X POST .../admin/api/global-settings -d '{"chunked_prefill":true}'
```

응답의 `runtime_applied` 배열에 필드 이름이 들어 있는지로 실제 반영을 확인하세요.
비어 있으면 적용되지 않은 것입니다.

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
| **`Qwen3.6-35B-A3B-4bit-DWQ`** | **19.3GB** | **메인** — 아래 비교 참고 |
| `Qwen3.6-35B-A3B-4bit` | 19GB | 이전 메인, 롤백용 |
| `Qwen3.6-35B-A3B-8bit` | 35GB | 품질 우선일 때 (단, 아래 참고) |
| `gemma-4-12B-it-OptiQ-4bit` | - | 컨텍스트 압축용 보조 모델 |
| `gemma-4-26b-a4b-it-4bit` | - | 범용 |
| `mlx-community--Llama-3.2-3B-Instruct-4bit` | - | 초경량 |

### 4bit vs 4bit-DWQ — 실측 비교 (2026-07-27)

DWQ(Distilled Weight Quantization)는 양자화된 가중치가 원본 출력을 따라가도록
**증류 학습**시킨 것입니다. 구조·크기·비트폭이 같으므로 연산량은 동일하고
가중치 *값*만 개선됩니다. 2~4비트 구간에서만 효과가 크다고 알려져 있습니다.

동일 조건(`turboquant_kv` 등 `model_settings.json` 전부 동일), 2회 독립 실행:

| 항목 | 4bit | **4bit-DWQ** |
|------|------|-------------|
| 크기 | 19.0 GB | 19.3 GB |
| 컨텍스트 | 262,144 | 262,144 |
| 프리필 40K (교대측정 3쌍 중앙값) | 17.9s | 18.5s — **동일** |
| 생성 속도 | 42.7~47.0 tok/s | 47.3~49.1 tok/s |
| **tool call 정확도** | 5/6 (2회 모두) | **6/6 (2회 모두)** |
| **완료 토큰 중앙값** | 695 | **287~320** |
| **과제 완료 시간** | 52~64s | **31~36s** |

4bit는 두 실행 모두 **같은 `web_search` 과제에서 1,839토큰을 쓰고도 도구를 호출하지
못한 채 종료**했습니다(`finish_reason=stop`). 재현되는 결함입니다.

DWQ가 과제를 45% 빨리 끝내는 이유는 생성 속도가 아니라 **reasoning 토큰을 2.2배
덜 쓰기 때문**입니다. 에이전트에서는 이게 복리로 작용합니다 — 출력이 짧으면
다음 턴에 프리필할 이력도 짧아집니다.

> **벤치마크 함정 두 가지 (둘 다 실제로 겪음)**
>
> 1. **순서 효과** — 두 번째로 도는 모델이 항상 느립니다. 첫 측정에서 "DWQ 프리필
>    2배 느림"이 나왔지만 순서를 뒤집으니 반대가 됐습니다. **반드시 교대 측정(A,B,A,B)**
>    으로 드리프트를 상쇄하세요.
> 2. **프롬프트 캐시** — 같은 텍스트를 재사용하면 91,385 tok/s 같은 허수가 나옵니다.
>    매번 고유 텍스트를 쓰고 `usage.prompt_tokens_details.cached_tokens == 0`을
>    확인해야 합니다. 랜덤 텍스트를 써도 적중하는 경우가 있으니 매 측정마다 확인하세요.

### 롤백

```bash
hermes config set model.default Qwen3.6-35B-A3B-4bit
hermes config set providers.omlx.default_model Qwen3.6-35B-A3B-4bit
hermes gateway restart
```

### 새 모델을 추가했는데 목록에 안 보일 때

oMLX는 **기동 시점에만** 모델을 탐색합니다. `omlx restart`가 "Successfully restarted"를
출력해도 실제 프로세스는 안 바뀔 수 있으니(brew 서비스 레이블만 조작됨), 재탐색 API를
쓰는 편이 확실합니다.

```bash
curl -s -X POST http://127.0.0.1:8000/admin/api/reload -H "Content-Type: application/json" -d '{}'
```

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
