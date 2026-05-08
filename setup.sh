#!/usr/bin/env bash
# ============================================================================
# hermes-m5max-setup — Apple Silicon Mac 전용 원클릭 로컬 AI 설정 스크립트
# 메모리 검출 → 자동 모델/컨텍스트 선택 → 전체 설정 자동화
# 작성일: 2026-05-07 (updated for multi-tier RAM support)
# 테스트 필요: macOS (Apple Silicon) — Python 3.11+, Docker Desktop
# ============================================================================
set -euo pipefail

# ── 색상/출력 유틸리티 ─────────────────────────────────────────────────────
BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()      { echo -e "${GREEN}[✓]${NC} $*"; }
warn()     { echo -e "${YELLOW}[!]${NC} $*"; }
err()      { echo -e "${RED}[✗]${NC} $*"; }
section()  { echo -e "\n${BOLD}▶ $*${NC}"; }

# ── RAM 메모리 크기 검출 ──────────────────────────────────────────────────
section("0. 시스템 정보 검출")

if [[ "$(uname)" != "Darwin" ]]; then
  err "이 스크립트는 macOS (Apple Silicon) 전용입니다."
  exit 1
fi

TOTAL_RAM_BYTES=$(sysctl -n hw.memsize 2>/dev/null || echo "0")
TOTAL_RAM_GB=$(( TOTAL_RAM_BYTES / 1073741824 ))

# 모델 정보
CPU_MODEL=$(system_profiler SPHardwareDataType 2>/dev/null | grep "Chip" | sed 's/.*: //')
echo "  칩: $CPU_MODEL"
echo "  메모리: ${TOTAL_RAM_GB}GB"

# 메모리 기반 모델/컨텍스트tier 정의 (2026-05-07 업데이트)
# 기준: 모델 가중치 + KV 캐시 + 시스템(~10GB) + 여유 8~10GB
# 사용자 테스트 결과 반영:
#   16~24GB : 컨텍스트 65K, 가벼운 모델 (27b는 MLX 아님)
#   32~40GB : 27b 4-bit (nvfp4), 컨텍스트 65K
#   48GB    : 35b-a3b mxfp8, 컨텍스트 65K
#   64GB    : 35b-a3b mxfp8, 컨텍스트 131K (약 83% 사용 — 충분)
#   72~95GB : 35b-a3b mxfp8, 컨텍스트 131K
#   96GB+   : 35b-a3b mxfp8, 컨텍스트 262K (최대)
if [[ $TOTAL_RAM_GB -lt 28 ]]; then
   # 16~24GB: M2/M3/M4 Pro
  PROFILE="pro_small"
  HERMES_MODEL="qwen3:4b"
  HERMES_CTX=32768
  BACKUP_MODEL="gemma3:4b"
  MCP_MODEL="qwen3:4b"
  FALLBACK_MODEL="llama-3.3-8b-instruct"
  warn "소용량 프로필: ${HERMES_MODEL} (ctx=${HERMES_CTX}) — 27b는 MLX 양자화 없음"

elif [[ $TOTAL_RAM_GB -lt 44 ]]; then
   # 32~40GB: M3/M4 Pro
  PROFILE="pro"
  HERMES_MODEL="qwen3:27b"
  HERMES_CTX=65536
  BACKUP_MODEL="gemma3:12b"
  MCP_MODEL="qwen3:27b"
  FALLBACK_MODEL="llama-3.1-70b-instruct"
  warn "중용량 프로필: ${HERMES_MODEL} 4-bit (ctx=${HERMES_CTX})"

elif [[ $TOTAL_RAM_GB -lt 60 ]]; then
   # 48GB: M4 Max
  PROFILE="max_small"
  HERMES_MODEL="qwen3.6:35b-a3b-coding-mxfp8"
  HERMES_CTX=65536
  BACKUP_MODEL="qwen3.6:35b-a3b-coding-nvfp4"
  MCP_MODEL="qwen3.6:35b-a3b-coding-mxfp8"
  FALLBACK_MODEL="llama-3.1-70b-instruct"
  warn "대용량-small 프로필: ${HERMES_MODEL} (ctx=${HERMES_CTX})"

elif [[ $TOTAL_RAM_GB -lt 80 ]]; then
   # 64GB: M2/M3/M4 Max
  PROFILE="max"
  HERMES_MODEL="qwen3.6:35b-a3b-coding-mxfp8"
  HERMES_CTX=131072
  BACKUP_MODEL="qwen3.6:35b-a3b-coding-nvfp4"
  MCP_MODEL="qwen3.6:35b-a3b-coding-mxfp8"
  FALLBACK_MODEL="llama-3.1-70b-instruct"
  log "최적 프로필: ${HERMES_MODEL} (ctx=${HERMES_CTX}) — 약 83% 메모리 사용"

elif [[ $TOTAL_RAM_GB -lt 96 ]]; then
   # 72~95GB: M2/M3/M4 Max 96GB
  PROFILE="max_large"
  HERMES_MODEL="qwen3.6:35b-a3b-coding-mxfp8"
  HERMES_CTX=131072
  BACKUP_MODEL="qwen3.6:35b-a3b-coding-nvfp4"
  MCP_MODEL="qwen3.6:35b-a3b-coding-mxfp8"
  FALLBACK_MODEL="llama-3.1-70b-instruct"
  log "대용량 프로필: ${HERMES_MODEL} (ctx=${HERMES_CTX})"

else
   # 96GB+: M1/M2/M3 Max 128GB/192GB
  PROFILE="max_ultra"
  HERMES_MODEL="qwen3.6:35b-a3b-coding-mxfp8"
  HERMES_CTX=262144
  BACKUP_MODEL="qwen3.6:35b-a3b-coding-nvfp4"
  MCP_MODEL="qwen3.6:35b-a3b-coding-mxfp8"
  FALLBACK_MODEL="llama-3.1-70b-instruct"
  log "초최대 프로필: ${HERMES_MODEL} (ctx=${HERMES_CTX} — 최대 컨텍스트)"
fi

# ── 체크포인트 1: Python 체크 ─────────────────────────────────────────────
section("1. Python 3 확인")

if ! command -v python3 &>/dev/null; then
  err "Python 3이 설치되어 있지 않습니다. (macOS 기본 Python 3.9+ 또는 pyenv 권장)"
  exit 1
fi

PYVER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
log "Python 버전: $PYVER"

# ── 체크포인트 2: Homebrew & 필수 도구 ────────────────────────────────────────
section("2. Homebrew 및 필수 도구")

if ! command -v brew &>/dev/null; then
  warn "Homebrew가 없습니다. 설치합니다..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install.sh)"
  log "Homebrew 설치 완료"
else
  log "Homebrew 발견"
fi

brew list jq >/dev/null 2>&1 || brew install jq
brew list yq >/dev/null 2>&1 || brew install yq
log "필수 도구: jq, yq"

# ── 체크포인트 3: Docker Desktop ──────────────────────────────────────────────
section("3. Docker Desktop")

if ! command -v docker &>/dev/null || ! docker info &>/dev/null 2>&1; then
  warn "Docker Desktop이 설치되지 않았습니다."
  warn "https://www.docker.com/products/docker-desktop/ 에서 설치 후 'Docker Desktop.app'을 실행하세요."
  warn "Docker Desktop이 시작되면 스크립트를 다시 실행하세요."
  exit 1
fi

log "Docker Desktop 실행 중"

# ── 체크포인트 4: Ollama (Homebrew 전용) ──────────────────────────────────────
section("4. Ollama 설치 및 컨텍스트 고정")

if ! command -v ollama &>/dev/null; then
  warn "Ollama가 없습니다. Homebrew로 설치합니다..."
  brew install --cask ollama
  log "Ollama 설치 완료 ($(ollama --version))"
else
  log "Ollama 발견 ($(ollama --version))"
fi

# Ollama 서비스 시작 (brew services)
if ! ollama health &>/dev/null; then
  warn "Ollama가 실행 중이 아닙니다. brew services로 시작합니다..."
  brew services start ollama
  sleep 3
  if ollama health &>/dev/null; then
    log "Ollama 서비스 시작됨"
  else
    warn "Ollama 서비스 시작 실패 — 'ollama serve'를 별도 터미널에서 실행하세요"
  fi
else
  log "Ollama 서비스: 이미 실행 중"
fi

# 목표 모델 pull
if ! ollama list | grep -q "$HERMES_MODEL"; then
  warn "주요 모델 $HERMES_MODEL이 없습니다. pull합니다..."
  ollama pull "$HERMES_MODEL"
  log "모델 pull 완료: $HERMES_MODEL"
else
  log "주요 모델 $HERMES_MODEL 이미 pull됨"
fi

# 백업 모델 pull
if ! ollama list | grep -q "$BACKUP_MODEL"; then
  warn "백업 모델 $BACKUP_MODEL이 없습니다. pull합니다..."
  ollama pull "$BACKUP_MODEL"
else
  log "백업 모델 $BACKUP_MODEL 이미 pull됨"
fi

# 컨텍스트 고정용 Modelfile 생성
MODELFILE_PATH="$HOME/Modelfile"
cat << EOF > "$MODELFILE_PATH"
FROM ${HERMES_MODEL}
PARAMETER num_ctx ${HERMES_CTX}
EOF
log "Modelfile 생성: $MODELFILE_PATH (num_ctx=${HERMES_CTX})"

# hermes 전용 모델 이름으로 빌드
HERMES_LABEL="${HERMES_MODEL}-hermes"
if ollama list | grep -q "$HERMES_LABEL"; then
  log "hermes용 레이블 '$HERMES_LABEL' 이미 존재"
  # 레이블이旧Modelfile로 생겼을 수 있으니 재생성
  MODELF_CHECK=$(ollama show "$HERMES_LABEL" --modelfile 2>/dev/null | grep -oP 'num_ctx\s+\K\d+' || echo "0")
  if [[ "$MODELF_CHECK" != "$HERMES_CTX" ]]; then
    warn "기존 레이블 num_ctx($MODELF_CHECK)이 다름. 재생성합니다..."
    ollama rm "$HERMES_LABEL" 2>/dev/null || true
    ollama create "$HERMES_LABEL" -f "$MODELFILE_PATH"
  fi
else
  warn "hermes용 레이블 '$HERMES_LABEL'을 Modelfile 기반으로 빌드합니다..."
  ollama create "$HERMES_LABEL" -f "$MODELFILE_PATH"
  log "hermes 레이블 빌드 완료: $HERMES_LABEL"
fi

# Ollama 환경변수 설정
ollama_env_dir="$HOME/.ollama"
ollama_env_file="$ollama_env_dir/env"
if [[ ! -d "$ollama_env_dir" ]]; then
  mkdir -p "$ollama_env_dir"
fi
cat << EOF > "$ollama_env_file"
OLLAMA_KEEP_ALIVE=-1
OLLAMA_CONTEXT_LENGTH=${HERMES_CTX}
EOF
log "Ollama 환경변수 저장: $ollama_env_file"

# launchctl 재로드
brew services restart ollama
sleep 2

if ollama health &>/dev/null; then
  log "Ollama: 정상 작동 중"
else
  warn "Ollama가 즉시 응답하지 않음. 'ollama serve'를 별도 터미널에서 실행하세요."
fi

# ── 체크포인트 5: Hermes Agent ────────────────────────────────────────────
section("5. Hermes Agent 설치")

HERMES_HOME="$HOME/.hermes"
HERMES_BIN="$HERMES_HOME/hermes-agent"

if command -v hermes &>/dev/null; then
  log "Hermes Agent 발견 ($(hermes --version 2>/dev/null || echo 'unknown'))"
else
  warn "Hermes Agent가 없습니다. 설치합니다..."
  if command -v pip3 &>/dev/null; then
    pip3 install hermes-agent 2>&1 | tail -3
  else
    python3 -m pip install hermes-agent 2>&1 | tail -3
  fi

  PATH_EXPORT='export PATH="$HOME/.hermes/hermes-agent/venv/bin:$PATH"'
  if grep -q "hermes-agent" "$HOME/.zshrc" 2>/dev/null; then
    log "PATH 이미 .zshrc에 설정됨"
  else
    echo "" >> "$HOME/.zshrc"
    echo "$PATH_EXPORT" >> "$HOME/.zshrc"
    log "PATH 설정: .zshrc 추가 완료"
  fi

  log "Hermes Agent 설치 완료"
fi

# ── 체크포인트 6: config.yaml ────────────────────────────────────────────
section("6. config.yaml 자동 생성")

CONFIG_FILE="$HERMES_HOME/config.yaml"

if [[ ! -f "$CONFIG_FILE" ]]; then
  warn "config.yaml이 없습니다. 프로필($PROFILE)에 맞게 생성합니다..."
  cat << YAML > "$CONFIG_FILE"
model:
  default: ${HERMES_LABEL}
  provider: custom
  base_url: http://127.0.0.1:11434/v1
  api_key: ollama
  context_length: ${HERMES_CTX}

providers: {}

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
    extra_body: {}
    download_timeout: 30
  web_extract:
    provider: custom
    base_url: https://generativelanguage.googleapis.com/v1beta/openai
    api_key: YOUR_GEMINI_API_KEY
    model: gemini-2.5-flash
    timeout: 360
    extra_body: {}
  compression:
    provider: custom
    base_url: https://generativelanguage.googleapis.com/v1beta/openai
    api_key: YOUR_GEMINI_API_KEY
    model: gemini-2.5-flash
    timeout: 120
    extra_body: {}
  session_search:
    provider: custom
    base_url: https://generativelanguage.googleapis.com/v1beta/openai
    api_key: YOUR_GEMINI_API_KEY
    model: gemini-2.5-flash
    timeout: 60
    extra_body: {}
    max_concurrency: 3
  mcp:
    provider: custom
    base_url: http://127.0.0.1:11434/v1
    api_key: ollama
    model: ${MCP_MODEL}
    timeout: 30
    extra_body: {}

fallback_providers:
   - provider: custom
    base_url: https://api.groq.com/openai/v1
    api_key: YOUR_GROQ_API_KEY
    model: ${FALLBACK_MODEL}

compression:
  enabled: true
  threshold: 0.4
  target_ratio: 0.15
  protect_last_n: 10

toolsets:
   - hermes-cli

session_reset:
  mode: both
  idle_minutes: 1440
  at_hour: 4
YAML
  log "config.yaml 생성 완료 — 프로필: $PROFILE (ctx=${HERMES_CTX})"
else
  # 기존 설정이 있으면 주요 필드만 업데이트
  log "config.yaml이 이미 존재합니다 — 프로필($PROFILE)에 맞게 주요 필드만 업데이트합니다"

  # context_length 업데이트
  sed -i '' "s/context_length: \d\+/context_length: ${HERMES_CTX}/" "$CONFIG_FILE" 2>/dev/null || true

  # fallback model 업데이트
  sed -i '' "s/model: llama-3.3-70b-versatile/model: ${FALLBACK_MODEL}/" "$CONFIG_FILE" 2>/dev/null || true
fi

# ── 체크포인트 7: API 키 설정 (대화형) ────────────────────────────────────
section("7. API 키 설정")

if ! grep -q "YOUR_GEMINI_API_KEY" "$CONFIG_FILE" 2>/dev/null; then
  log "API 키가 이미 설정되어 있음"
else
  warn "아직 API 키가 설정되지 않았습니다."
  echo ""
  echo "아래 API 키들을 입력하세요 (엔터를 치면 건너뜁니다):"
  echo ""
  echo "  Gemini API 키:"
  echo "     → https://aistudio.google.com/app/apikey 에서 생성"
  echo ""
  read -r -p "  Gemini API 키 > " GEMINI_KEY

  if [[ -n "$GEMINI_KEY" && "$GEMINI_KEY" != "YOUR_GEMINI_API_KEY" ]]; then
    sed -i '' "s/YOUR_GEMINI_API_KEY/$GEMINI_KEY/g" "$CONFIG_FILE"
    log "Gemini API 키 설정 완료"
  else
    warn "Gemini API 키를 건너뜁니다 (~1500 req/일 무료 티어)"
  fi

  echo ""
  echo "  Groq API 키:"
  echo "     → https://console.groq.com/keys 에서 생성"
  echo ""
  read -r -p "  Groq API 키 > " GROQ_KEY

  if [[ -n "$GROQ_KEY" && "$GROQ_KEY" != "YOUR_GROQ_API_KEY" ]]; then
    sed -i '' "s/YOUR_GROQ_API_KEY/$GROQ_KEY/g" "$CONFIG_FILE"
    log "Groq API 키 설정 완료"
  else
    warn "Groq API 키를 건너뜁니다 (~1000 req/일 무료 티어)"
  fi
fi

# ── 체크포인트 8: Open WebUI (Docker) ─────────────────────────────────────
section("8. Open WebUI 설치 (Docker)")

EXISTING_WEBUI=$(docker ps -a --filter "name=open-webui" --format "{{.Names}}" 2>/dev/null || echo "")

if [[ -n "$EXISTING_WEBUI" ]]; then
  WEBUI_STATUS=$(docker inspect --format '{{.State.Status}}' "$EXISTING_WEBUI" 2>/dev/null || echo "unknown")
  if [[ "$WEBUI_STATUS" == "running" ]]; then
    log "Open WebUI 컨테이너가 이미 실행 중입니다"
  elif [[ "$WEBUI_STATUS" == "exited" || "$WEBUI_STATUS" == "dead" ]]; then
    warn "기존 Open WebUI 컨테이너가 중지되었습니다. 재시작합니다..."
    docker start "$EXISTING_WEBUI"
    log "재시작 완료"
  fi
else
  warn "Open WebUI가 설치되지 않았습니다. Docker로 시작합니다..."
  docker pull ghcr.io/open-webui/open-webui:main 2>&1 | tail -1
  docker run -d \
    --name open-webui \
    -p 3000:8080 \
    --add-host=host.docker.internal:host-gateway \
    -e WEBUI_AUTH=False \
    -e ENABLE_SEARCH=true \
    ghcr.io/open-webui/open-webui:main
  log "Open WebUI 컨테이너 시작됨"
  sleep 3
fi

# 헬스체크
MAX_RETRIES=10
WEBSITE_URL="http://localhost:3000"
for i in $(seq 1 $MAX_RETRIES); do
  if curl -sf "$WEBSITE_URL" &>/dev/null; then break; fi
  sleep 2
done

if curl -sf "$WEBSITE_URL" &>/dev/null; then
  log "Open WebUI 접근 가능: $WEBSITE_URL"
  warn "설정 → Connections → Base URL: http://host.docker.internal:11434/v1"
else
  warn "Open WebUI 시작 중... 잠시 후 접속하세요"
fi

# ── 체크포인트 9: MLX 가상환경 ────────────────────────────────────────────
section("9. MLX 가상환경")

MLX_VENV="$HOME/mlx-env"

if [[ ! -d "$MLX_VENV" ]]; then
  warn "MLX 가상환경이 없습니다. 생성합니다..."
  python3 -m venv "$MLX_VENV"
  (
    source "$MLX_VENV/bin/activate"
    pip install mlx-lm 2>&1 | tail -2
  )
  log "MLX 가상환경 생성: $MLX_VENV"
else
  log "MLX 가상환경 이미 존재: $MLX_VENV"
fi

# 활성화 스크립트 추가
SOURCE_CMD="source $MLX_VENV/bin/activate 2>/dev/null"
if grep -q "mlx-env" "$HOME/.zshrc" 2>/dev/null; then
  log "MLX activate 문이 .zshrc에 이미 있음"
else
  echo "" >> "$HOME/.zshrc"
  echo "# MLX 환경 (ollama MLX 모델 로딩용)" >> "$HOME/.zshrc"
  echo "$SOURCE_CMD" >> "$HOME/.zshrc"
  log "MLX venv activate를 .zshrc에 추가"
fi

# ── 체크포인트 10: 최종 정리 ────────────────────────────────────────────
section("10. 설치 완료! — 다음 단계")

echo ""
echo -e "${BOLD}═══ 설치가 완료되었습니다! ═══${NC}"
echo ""
echo "  프로필        : $PROFILE"
echo "  주요 모델     : $HERMES_LABEL ($HERMES_MODEL, ${HERMES_CTX} ctx)"
echo "  백업 모델     : $BACKUP_MODEL"
echo "  Ollama URL    : http://localhost:11434/v1"
echo "  Hermes        : hermes"
echo "  Open WebUI    : http://localhost:3000"
echo ""
echo -e "${BOLD}수동 작업:${NC}"
echo "  1. 새 터미널: source ~/.zshrc"
echo "  2. Ollama 상태: ollama ps"
echo "  3. Hermes 시작: hermes"
echo "  4. WebUI 설정: Connections → Ollama URL = http://host.docker.internal:11434/v1"
echo "  5. WebUI 설정: Web Search → SearXNG 또는 DuckDuckGo"
echo ""
echo -e "${BOLD}🔑 API 키 확인:${NC} nano ~/.hermes/config.yaml"
echo ""

# ── 검증 스크립트 생성 ──────────────────────────────────────────────────
VSCRIPT_PATH="$HOME/Projects/hermes-m5max-setup/verify_setup.sh"
cat << 'VERIFY_EOF' > "$VSCRIPT_PATH"
#!/usr/bin/env bash
# hermes-m5max-setup 검증 스크립트
set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()     { echo -e "${GREEN}[✓]${NC} $*"; }
fail()   { echo -e "${RED}[✗]${NC} $*"; }
warn()   { echo -e "${YELLOW}[!]${NC} $*"; }

CHECKS_PASSED=0
CHECKS_TOTAL=0

check() {
  CHECKS_TOTAL=$((CHECKS_TOTAL + 1))
  if ($@ >/dev/null 2>&1); then
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
    ok "$*"
  else
    fail "$*"
  fi
}

echo "═══════════════════════════════════════════"
echo "  hermes-m5max-setup 검증 스크립트"
echo "═══════════════════════════════════════════"
echo ""

# RAM 검출
TOTAL_RAM_GB=$(( $(sysctl -n hw.memsize) / 1073741824 ))
echo "  시스템: macOS, $TOTAL_RAM_GBGB ($CPU_MODEL)"
echo ""

# 1. Python
check "python3 --version"

# 2. Ollama
check "command -v ollama"

# 3. Ollama 서비스
if ollama health &>/dev/null; then
  ok "Ollama 서비스: 응답 중"
  CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
  warn "Ollama 서비스: 응답 없음"
fi
CHECKS_TOTAL=$((CHECKS_TOTAL + 1))

# 4. 모델 목록
MODELS=$(ollama list 2>/dev/null || echo "")

# 5. Hermes Agent
check "command -v hermes"

# 6. config.yaml
if [[ -f "$HOME/.hermes/config.yaml" ]]; then
  ok "config.yaml 존재"
  CTX=$(grep "context_length:" "$HOME/.hermes/config.yaml" | head -1 | awk '{print $2}')
  MAIN_MODEL=$(grep "default:" "$HOME/.hermes/config.yaml" | head -1 | awk '{print $2}')
  ok "config.yaml: 기본 모델=$MAIN_MODEL, ctx=$CTX"
  if grep -q "YOUR_GEMINI_API_KEY" "$HOME/.hermes/config.yaml"; then
    warn "Gemini API 키: 아직 설정 안됨"
  else
    ok "Gemini API 키 설정됨"
  fi
  if grep -q "YOUR_GROQ_API_KEY" "$HOME/.hermes/config.yaml"; then
    warn "Groq API 키: 아직 설정 안됨"
  else
    ok "Groq API 키 설정됨"
  fi
else
  fail "config.yaml 없음"
fi

# 7. Docker
check "docker info"

# 8. Open WebUI
if docker ps --filter "name=open-webui" --format "{{.Names}}" | grep -q "open-webui"; then
  OW_STATUS=$(docker inspect --format '{{.State.Status}}' open-webui 2>/dev/null)
  if [[ "$OW_STATUS" == "running" ]]; then
    ok "Open WebUI: 실행 중"
  else
    warn "Open WebUI: 중지됨 ($OW_STATUS)"
  fi
else
  warn "Open WebUI: 설치 안됨"
fi

# 9. MLX venv
if [[ -d "$HOME/mlx-env" ]]; then
  ok "MLX venv 존재"
else
  warn "MLX venv 없음"
fi

# 10. Modelfile num_ctx
MODELF_CTX=$(cat "$HOME/Modelfile" 2>/dev/null | grep -oP 'num_ctx\s+\K\d+' || echo "0")
if [[ "$MODELF_CTX" -gt 0 ]]; then
  ok "Modelfile num_ctx: $MODELF_CTX"
else
  warn "Modelfile num_ctx: 검출 안됨"
fi

echo ""
echo "결과: $CHECKS_PASSED/$CHECKS_TOTAL 확인 항목 통과"
if [[ $CHECKS_PASSED -eq $CHECKS_TOTAL ]]; then
  echo -e "${GREEN}✓ 전체 설정이 완료되었습니다!${NC}"
elif [[ $CHECKS_PASSED -ge $((CHECKS_TOTAL - 2)) ]]; then
  echo -e "${YELLOW}! 거의 완료되었습니다 — 몇 가지 항목을 확인하세요${NC}"
else
  echo -e "${RED}! 중요한 항목이 누락되었습니다. setup.sh를 다시 실행하세요${NC}"
fi
VERIFY_EOF

chmod +x "$VSCRIPT_PATH"
log "검증 스크립트 생성: $VSCRIPT_PATH"

echo ""
echo "  ▶ 검증 실행: bash ~/Projects/hermes-m5max-setup/verify_setup.sh"
echo ""
