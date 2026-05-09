# 로컬 AI 셋업 가이드 (Apple Silicon M5 Max)

> **작성일**: 2026-05-07
> **환경**: MacBook Pro M5 Max / 64GB 통합 메모리

---

## 1. 환경 개요

| 항목 | 내용 |
|------|------|
| 기기 | MacBook Pro M5 Max |
| 메모리 | 64GB 통합 메모리 |
| 시스템 점유 | ~10GB |
| 사용 가능 | ~54GB |
| 주요 도구 | Ollama + Hermes Agent |

### 메모리 구조

```
64GB 총합
├── 시스템: ~10GB
├── 모델 가중치: 모델 크기에 따라 (20~38GB)
├── KV 캐시: 컨텍스트 크기에 따라
└── 여유: 나머지
```

---

## 2. Python 패키지 설치

### 기본 설치
```bash
pip3 install 패키지명
# 또는
python3 -m pip install 패키지명
```

### externally-managed-environment 에러 시
```bash
# 가상환경 사용 (권장)
python3 -m venv ~/mlx-env
source ~/mlx-env/bin/activate
pip install mlx-lm

# 이후 매번 활성화
source ~/mlx-env/bin/activate
```

---

## 3. Ollama 설치 및 설정

### 컨텍스트 고정 (Modelfile 방식 — 권장)
```bash
cat << 'EOF' > ~/Modelfile
FROM qwen3.6:35b-a3b-coding-mxfp8
PARAMETER num_ctx 65536
EOF
ollama create qwen3.6-hermes -f ~/Modelfile
```

> ⚠️ `OLLAMA_CONTEXT_LENGTH` 환경변수는 일부 버전에서 무시됩니다. Modelfile로 설정하는 것이 확실합니다.

### 유용한 명령어
```bash
ollama list               # 보유 모델 목록
ollama ps                 # 현재 실행 중인 모델
ollama show 모델명         # 모델 상세 정보
ollama stop 모델명         # 모델 중지
ollama rm 모델명           # 모델 삭제
```

### Ollama vs LM Studio

| 항목 | Ollama | LM Studio |
|------|--------|-----------|
| KV 캐시 할당 | 동적 | 사전 할당 (메모리 낭비) |
| 컨텍스트 설정 | Modelfile | GUI |
| MLX 지원 | ✅ (태그로 구분) | ✅ 네이티브 |
| 메모리 효율 | 높음 | 낮음 |
| Hermes 연동 | 공식 지원 | OpenAI 호환 |
| 멀티 모델 동시 실행 | ✅ | ❌ |
| **결론** | Hermes 백엔드 추천 | 모델 탐색/테스트 용 |

---

## 4. 모델 목록 및 선택 기준

### M5 Max 보유 모델

| 모델 | 크기 | 타입 | 용도 |
|------|------|------|------|
| `qwen3.6:latest` | 24GB | GGUF Q4\_K\_M | 범용 |
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
- nvfp4 ≠ NVIDIA 전용 — Ollama에서 MLX 태그로 Apple Silicon에서 실행됨

---

## 5. Hermes Agent 설치 및 설정

### PATH 설정
```bash
echo 'export PATH="$HOME/.hermes/hermes-agent/venv/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
hermes
```

### 기본 실행
```bash
# 터미널 1: Ollama 서버 시작
OLLAMA_KEEP_ALIVE=-1 ollama serve

# 터미널 2: Hermes 실행
hermes
```

### 유용한 Hermes 명령어
```
/compress      # 컨텍스트 즉시 압축
/status        # 현재 상태 확인
/reset         # 새 세션 시작
```

### config.yaml 위치
```bash
~/.hermes/config.yaml
```

---

## 6. 메모리 관리 및 컨텍스트 설정

### KV 캐시 계산 공식
```
KV 캐시 (GB) = 2 × 컨텍스트 × 레이어 수 × KV헤드 수 × 헤드 차원 × (비트수/8) / 1GB
```

> MLX는 KV 캐시를 fp16으로 저장합니다 — 4비트 모델도 KV 캐시는 16비트로 동작합니다.

### 컨텍스트 크기별 메모리 (Qwen3.6 35B 기준)

|| 컨텍스트 | KV 캐시 | 총 메모리 | 안전도 |
||---------|---------|----------|--------|
|| 262K (기본값) | ~38GB | ~86GB | ❌ 초과 |
|| 131K | ~15GB | ~63GB | ⚠️ 위험하지만 64GB에서 사용 중 |
|| 65K | ~7GB | ~55GB | ✅ 안전 |
|| 32K | ~4GB | ~52GB | ✅ 여유 |

### 권장 설정 (현재 — 64GB 기준)
```yaml
# config.yaml (최신)
model:
  context_length: 131072
```
예상 메모리: **약 83% 사용 (64GB 기준)**

### 컨텍스트가 너무 크면 생기는 문제
1. **메모리 부족 → 모델 언로드** (90% → 14% 뚝 떨어짐)
2. **속도 저하** (어텐션 계산량 선형 증가)
3. **Wired 메모리 누수** (재부팅 필요)
4. **실질적으로 더 짧은 대화** (중간에 모델 내려가므로)

### 압축 설정 최적화 (최신)
```yaml
compression:
  enabled: true
  threshold: 0.5         # 50%에서 자동 압축
  target_ratio: 0.2      # 20%까지 압축
  protect_last_n: 20     # 최근 20개 보호
```

> 💡 `threshold`를 낮추면 더 일찍 압축이 시작되고, `target_ratio`를 낮추면 더 강하게 압축됩니다.

### 개인 정보 보호 (PII Redaction)
```yaml
privacy:
  redact_pii: true       # 외부 AI(압축/웹추출 등) 전송 시 개인 식별 정보 자동 감쇄
  redact_secrets: true   # API 키, 비밀번호 등 시크릿 자동 감쇄 (기본값)
```
> ⚠️ compression에 Gemini 같은 외부 AI 모델을 사용하면 대화 내용에 이름, 주소, 전화번호 등 개인 정보가 포함될 수 있습니다. `redact_pii: true`는 외부 모델이 컨텍스트를 요약할 때 이 정보를 감춰줍니다.

---

## 7. 다중 모델 하이브리드 설정 (config.yaml)

```yaml
# 메인: 로컬 Ollama (무제한, 무료)
model:
  default: qwen3.6-hermes
  provider: custom
  base_url: http://127.0.0.1:11434/v1
  api_key: ollama
  context_length: 131072

custom_providers:
  - name: gemini-free
    base_url: https://generativelanguage.googleapis.com/v1beta/openai
    api_key: YOUR_GEMINI_API_KEY
    api_mode: chat_completions
  - name: groq-free
    base_url: https://api.groq.com/openai/v1
    api_key: YOUR_GROQ_API_KEY
    api_mode: chat_completions

auxiliary:
  vision:
    provider: custom
    base_url: https://generativelanguage.googleapis.com/v1beta/openai
    api_key: YOUR_GEMINI_API_KEY
    model: gemini-2.5-flash
    timeout: 120
  web_extract:
    provider: custom
    base_url: https://generativelanguage.googleapis.com/v1beta/openai
    api_key: YOUR_GEMINI_API_KEY
    model: gemini-2.5-flash
    timeout: 360
  compression:
    provider: custom
    base_url: https://generativelanguage.googleapis.com/v1beta/openai
    api_key: YOUR_GEMINI_API_KEY
    model: gemini-2.5-flash
    timeout: 120
  session_search:
    provider: custom
    base_url: https://generativelanguage.googleapis.com/v1beta/openai
    api_key: YOUR_GEMINI_API_KEY
    model: gemini-2.5-flash
    timeout: 30
    max_concurrency: 3
  mcp:
    provider: custom
    base_url: http://127.0.0.1:11434/v1
    api_key: ollama
    model: qwen3.6:35b-a3b-coding-nvfp4
    timeout: 30

fallback_providers:
  - provider: custom
    base_url: https://api.groq.com/openai/v1
    api_key: YOUR_GROQ_API_KEY
    model: llama-3.3-70b-versatile
```

---

## 8. 무료 클라우드 API 역할 분담

### 무료 티어 한도

| 서비스 | 무료 한도 | 특징 |
|--------|----------|------|
| Gemini Flash | 1,500 req/일, 1M TPM | 가장 넉넉함 |
| Groq | 1,000 req/일, 6K TPM | 가장 빠름 |
| Claude API | 초기 크레딧만 | API 무료 없음 |
| xAI Grok | 소량 | 불안정 |

### 역할 분담 전략

| 모델 | 역할 |
|------|------|
| 로컬 Ollama Qwen3.6 | 메인 대화, tool calling, 추론 (무제한) |
| Gemini Flash | 웹추출, 컨텍스트 압축, 이미지 분석 (TPM 여유) |
| Groq Llama | 로컬 다운됐을 때 폴백 (빠른 응답) |

### 토큰 많이 먹는 작업 순서
1. 시스템 프롬프트 + 툴 스키마 (매 턴 4~6K)
2. 컨텍스트 압축
3. 웹서치 결과 추출
4. 이미지/비전 분석
5. 일반 대화 응답

---

## 9. 웹 서치 연동 (Open WebUI)

> LM Studio 자체에는 웹서치 기능이 없습니다. Open WebUI가 필요합니다.

### Docker로 설치
```bash
docker run -d -p 3000:8080 --add-host=host.docker.internal:host-gateway \
   -e WEBUI_AUTH=False \
  ghcr.io/open-webui/open-webui:main
```

### 접속 및 설정
1. `http://localhost:3000` 접속
2. Settings → Connections → Base URL: `http://host.docker.internal:11434/v1`
3. Settings → Web Search → SearXNG 또는 DuckDuckGo 선택
4. 채팅창 🌐 아이콘 클릭 후 질문

### 삭제
```bash
docker rm -f 컨테이너이름    # docker ps -a 로 이름 확인
docker rmi ghcr.io/open-webui/open-webui:main
```

---

## 10. 트러블슈팅

### MLX 모델 로드 실패
```
ValueError: [quantize] The requested group size 16 is not supported.
```
→ 해당 모델이 비표준 양자화. GGUF 버전으로 변경하거나 다른 양자화 선택.

### Hermes 실행 오류
```
OSError: [Errno 22] Invalid argument
KeyError: '0 is not registered'
```
→ PATH 설정 후 재실행:
```bash
echo 'export PATH="$HOME/.hermes/hermes-agent/venv/bin:$PATH"' >> ~/.zshrc
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
→ 컨텍스트 크기가 너무 큼. Modelfile에서 `num_ctx` 줄이기:
```bash
cat << 'EOF' > ~/Modelfile
FROM 모델명
PARAMETER num_ctx 65536
EOF
ollama create 모델명-hermes -f ~/Modelfile
```

### /compress 안 먹힐 때
→ auxiliary compression API 키 확인:
```bash
cat ~/.hermes/config.yaml | grep -A 6 "compression:"
```

---

## 빠른 참조 치트시트

```bash
# Ollama 서버 시작
OLLAMA_KEEP_ALIVE=-1 ollama serve

# 새 터미널에서 Hermes 시작
hermes

# 모델 목록
ollama list

# 현재 실행 중인 모델 확인
ollama ps

# Modelfile로 모델 생성 (컨텍스트 고정)
cat << 'EOF' > ~/Modelfile
FROM qwen3.6:35b-a3b-coding-mxfp8
PARAMETER num_ctx 65536
EOF
ollama create qwen3.6-hermes -f ~/Modelfile

# config.yaml 수정
nano ~/.hermes/config.yaml
# 저장: Ctrl+O → Enter → Ctrl+X
```
