# Hermes Agent & Local AI Setup Guide (Apple Silicon M5 Max)

> 내 깃 저장소 — Hermes Agent와 로컬 LLM을 Apple Silicon Mac에 셋업하는 가이드 + 자동화 스크립트 모음입니다.

## 📋 목차

- [환경 개요](#환경-개요)
- [Quick Start](#quick-start)
- [구성 파일](#구성-파일)
- [설정값 참고](#설정값-참고)
- [자가 진단](#자가-진단)
- [트러블슈팅](#트러블슈팅)
- [모델 선택 가이드](#모델-선택-가이드)

---

## 환경 개요

| 항목 | 내용 |
|------|------|
| 기기 | MacBook Pro M5 Max |
| 메모리 | 64GB 통합 메모리 |
| 시스템 점유 | ~10GB |
| 사용 가능 | ~54GB |
| 주요 도구 | Ollama + Hermes Agent |

---

## Quick Start

### 1. Ollama 서버 실행 (터미널 1)

```bash
OLLAMA_KEEP_ALIVE=-1 ollama serve
```

### 2. Hermes Agent 실행 (터미널 2)

```bash
hermes
```

PATH가 안 걸려 있으면:

```bash
export PATH="$HOME/.hermes/hermes-agent/venv/bin:$PATH"
source ~/.zshrc
hermes
```

### 3. 자동으로 모델 빌드 (컨텍스트 고정)

```bash
cat << 'EOF' > ~/Modelfile
FROM qwen3.6:35b-a3b-coding-mxfp8
PARAMETER num_ctx 65536
EOF
ollama create qwen3.6-hermes -f ~/Modelfile
```

---

## 구성 파일

```
hermes-m5max-setup/
├── README.md          # 이 파일
├── setup.sh           # 자동 설치 스크립트
└── docs/
    └── wellgroomed.md # 상세 가이드 (모델, 메모리, 압축 등)
```

### 핵심 설정 파일

- `~/.hermes/config.yaml` — Hermes 에이전트 전체 설정
- `~/Modelfile` — Ollama 모델 빌드 파일 (컨텍스트 고정용)
- `~/.ollama/config.json` — Ollama 기본 설정

---

## 설정값 참고

### Hermes Agent (config.yaml) — 최신값

```yaml
model:
  context_length: 131072    # 64GB 기준, ~83% 메모리 사용

compression:
  enabled: true
  threshold: 0.5           # 50%에서 자동 압축
  target_ratio: 0.2        # 20%까지 압축
  protect_last_n: 20       # 최근 20개 대화 보호

privacy:
  redact_pii: true         # 외부 AI 전송 시 PII 자동 감쇄
  redact_secrets: true     # API 키/비밀번호 자동 감쇄
```

### 컨텍스트별 메모리 (Qwen3.6 35B 기준)

| 컨텍스트 | KV 캐시 | 총 메모리 | 안전도 |
|---------|---------|----------|--------|
| 262K | ~38GB | ~86GB | ❌ 초과 |
| 131K | ~15GB | ~63GB | ⚠️ 64GB에서 사용 중 |
| 65K | ~7GB | ~55GB | ✅ 안전 |
| 32K | ~4GB | ~52GB | ✅ 여유 |

KV 캐시 공식:

```
KV 캐시 (GB) = 2 × 컨텍스트 × 레이어 수 × KV헤드 수 × 헤드 차원 × (비트수/8) / 1GB
```

> MLX는 KV 캐시를 fp16으로 저장합니다. 4비트 모델도 KV 캐시는 16비트로 동작합니다.

### 다중 모델 아키텍처

| 모델 | 역할 |
|------|------|
| 로컬 Ollama Qwen3.6 | 메인 대화, tool calling, 추론 (무제한) |
| Gemini Flash (Google) | 웹추출, 컨텍스트 압축, 이미지 분석 (TPM 여유) |
| Groq Llama 3.3 70B | 로컬 모델 다운 시 폴백 |

---

## 자가 진단

```bash
# config.yaml 압축 설정 확인
cat ~/.hermes/config.yaml | grep -A 6 "compression:"

# Ollama 모델 목록
ollama list

# 현재 실행 중인 모델
ollama ps

# 컨텍스트 설정 확인
ollama show qwen3.6-hermes | grep num_ctx

# 메모리 사용량
vm_stat | grep "Pages active"
```

---

## 트러블슈팅

### MLX 모델 로드 실패

```
ValueError: [quantize] The requested group size 16 is not supported.
```
→ 비표준 양자화 모델. GGUF 버전이나 다른 양자화(Q4_K_M, mxfp8)으로 변경.

### Hermes 실행 오류

```
OSError: [Errno 22] Invalid argument
KeyError: '0 is not registered'
```
→ PATH 설정 후 재실행:
```bash
source ~/.zshrc
hermes
```

### Ollama 서버 연결 안 될 때

```
Error: could not connect to ollama server
```
→ 별도 터미널에서 먼저 서버 실행:
```bash
OLLAMA_KEEP_ALIVE=-1 ollama serve
```

### 메모리 90% 이상 → 모델 언로드 반복
→ 컨텍스트 크기를 줄입니다. Modelfile에서 `num_ctx 65536`으로 낮추고 재생성.

### /compress 안 먹힐 때
→ auxiliary compression API 키가 설정되어 있는지 확인:
```bash
cat ~/.hermes/config.yaml | grep -A 6 "compression:"
```

---

## 모델 선택 가이드

### 보유 모델 및 용도

| 모델 | 크기 | 타입 | 용도 |
|------|------|------|------|
| `qwen3.6:latest` | 24GB | GGUF Q4_K_M | 범용 |
| `qwen3.6:27b` | 17GB | GGUF | 가벼운 범용 |
| `qwen3.6:35b-a3b-coding-nvfp4` | 22GB | MLX | 코딩 특화 / 빠름 |
| `qwen3.6:35b-a3b-coding-mxfp8` | 38GB | MLX | 코딩 특화 / 고품질 |
| `gemma4:e4b` | 9.6GB | - | 초경량 / 빠름 |
| `gemma4:26b` | 17GB | - | 균형 |
| `gemma4:31b` | 19GB | - | 고품질 |

### 추천 조합

| 용도 | 모델 | 이유 |
|------|------|------|
| Hermes 메인 | `qwen3.6:35b-a3b-coding-mxfp8` | MLX 고품질, tool calling 우수 |
| 가벼운 대화 | `gemma4:e4b` | 빠르고 작음 |

### MLX vs GGUF

- **MLX**: Apple Silicon 최적화, Metal GPU 활용, 약 2배 빠름
- **GGUF**: Ollama 표준 포맷, 범용적
- **nvfp4 / mxfp8**: MLX 전용 포맷 (NVIDIA 전용 아님, 이름만 혼동 주의)

---

더 자세한 내용은 [`docs/wellgroomed.md`](docs/wellgroomed.md)를 참고하세요.
