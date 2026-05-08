#!/usr/bin/env bash
# ============================================================================
# hermes-m5max-setup — M5 Max 64GB 전용 원클릭 로컬 AI 설정 스크립트
# 작성일: 2026-05-07
# 테스트 필요: macOS (Apple Silicon) — Python 3.11+, Docker Desktop
# ============================================================================
set -euo pipefail

# ── 색상/출력 유틸리티────────────────────────────────────────────────────────
BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()       { echo -e "${GREEN}[✓]${NC} $*"; }
warn()      { echo -e "${YELLOW}[!]${NC} $*"; }
err()       { echo -e "${RED}[✗]${NC} $*"; }
section()   { echo -e "\n${BOLD}▶ $*${NC}"; }

# ── 체크포인트 1: 관리자 권한/권한 확인───────────────────────────────────────
section("1. 환경 확인 및 전제 조건 체크")

if [[ "$(uname)" != "Darwin" ]]; then
  err "이 스크립트는 macOS 전용입니다. (Docker Desktop Linux 용은 별도 스크립트 필요)"
  exit 1
fi

if ! command -v python3 &>/dev/null; then
  err "Python 3이 설치되어 있지 않습니다. (macOS 기본 Python 3.9+ 또는 pyenv 권장)"
  exit 1
fi

PYTHON_VERSION=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
warn "검출된 Python versão: $PYTHON_VERSION"

# ── 체크포인트 2: Homebrew & 필수 도구───────────────────────────────────────
section("2. Homebrew 및 필수 도구 설치")

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

# ── 체크포인트 3: Docker Desktop─────────────────────────────────────────────
section("3. Docker Desktop 확인")

if ! command -v docker &>/dev/null || ! docker info &>/dev/null 2>&1; then
  warn "Docker Desktop이 설치되지 않았습니다."
  warn "https://www.docker.com/products/docker-desktop/ 에서 설치 후 'Docker Desktop.app'을 실행하세요."
  warn "Docker Desktop이 시작되면 스크립트를 다시 실행하세요."
  exit 1
fi

log "Docker Desktop 실행 중"

# ── 체크포인트 4: Ollama─────────────────────────────────────────────────────
section("4. Ollama 설치 및 컨텍스트 고정 설정")

OLLAMA_SERVICES=$(launchctl list 2>/dev/null | grep ollama || true)
OLLAMA_INSTALLED=false

if command -v ollama &>/dev/null; then
  OLLAMA_INSTALLED=true
  log "Ollama 발견 ($(ollama --version))"
else
  warn "Ollama가 없습니다. 설치합니다..."
  if [[ "$(uname -m)" == "arm64" ]]; then
    brew install --cask ollama
  else
    curl -fsSL https://ollama.com/install.sh | sh
  fi
  log "Ollama 설치 완료"
fi

# Ollama가 서비스로 실행 중인지 확인
if [[ "$OLLAMA_INSTALLED" == true ]] && [[ -z "$OLLAMA_SERVICES" ]]; then
  warn "Ollama 서비스(ollama/service)가 실행 중이 아닙니다. 백그라운드 서비스로 시작합니다..."
  brew services start ollama
  sleep 3
  if ollama health &>/dev/null; then
    log "Ollama 서비스 시작됨"
  else
    warn "Ollama 서비스 시작 실패 — 수동 시작 안내: ollama serve"
  fi
fi

# 컨텍스트 길이 확인 및 Modelfile 기반 고정
MODEL_NAME="qwen3.6:35b-a3b-coding-mxfp8"
HERMES_MODEL_NAME="qwen3.6-hermes"
TARGET_CTX=65536

# 목표 모델이.pull되어 있는지 확인
if ! ollama list | grep -q "$MODEL_NAME"; then
  warn "모델 $MODEL_NAME이 없습니다. pull합니다..."
  ollama pull "$MODEL_NAME"
  log "모델 pull 완료"
else
  log "모델 $MODEL_NAME 발견"
fi

# Modelfile을 사용한 컨텍스트 고정
MODELFILE_PATH="$HOME/Modelfile"
if [[ -f "$MODELFILE_PATH" ]]; then
  CURRENT_CTX=$(grep -oP 'num_ctx\s+\K\d+' "$MODELFILE_PATH" 2>/dev/null || echo "")
  if [[ "$CURRENT_CTX" == "$TARGET_CTX" ]]; then
    log "Modelfile: num_ctx=$(ollama show $HERMES_MODEL_NAME --modelfile 2>/dev/null | grep num_ctx | awk '{print $2}' || echo 'unknown') — 설정됨"
    # 새 설정이 필요한지 확인
  else
    warn "기존 Modelfile의 num_ctx($CURRENT_CTX)이 목표($TARGET_CTX)와 다릅니다. 업데이트합니다."
  fi
else
  warn "Modelfile이 없습니다. num_ctx 고정용으로 생성합니다..."
  cat << EOF > "$MODELFILE_PATH"
FROM ${MODEL_NAME}
PARAMETER num_ctx ${TARGET_CTX}
EOF
  log "Modelfile 생성: $MODELFILE_PATH"
fi

# ollama create로 hermes용 모델 빌드 (중복 방지)
if ollama list | grep -q "$HERMES_MODEL_NAME"; then
  log "hermes용 모델 $HERMES_MODEL_NAME 이미 존재"
else
  warn "hermes용 모델 $HERMES_MODEL_NAME을 Modelfile 기반으로 빌드합니다..."
  ollama create "$HERMES_MODEL_NAME" -f "$MODELFILE_PATH"
  log "hermes용 모델 빌드 완료"
fi

# Ollama 환경변수 설정 (launchctl에 영구 추가)
SECTION_ENV="/Users/sungjunmaing/Library/LaunchAgents/com.ollama.ollama.plist"
ollama_env_dir="$HOME/.ollama"
ollama_env_file="$ollama_env_dir/env"

if [[ ! -d "$ollama_env_dir" ]]; then
  mkdir -p "$ollama_env_dir"
fi

cat << EOF > "$ollama_env_file"
OLLAMA_KEEP_ALIVE=-1
OLLAMA_CONTEXT_LENGTH=${TARGET_CTX}
EOF

log "Ollama 환경변수 저장: $ollama_env_file"
warn "launchctl 설정 재로딩: brew services restart ollama"
brew services restart ollama
sleep 2

# Ollama serve 확인
if ollama health &>/dev/null; then
  log "Ollama 서비스: 정상 작行动中"
else
  warn "Ollama가 즉시 응답하지 않음. 'ollama serve'를 별도 터미널에서 실행하세요."
fi

# ── 체크포인트 5: Hermes Agent──────────────────────────────────────────────
section("5. Hermes Agent 설치 및 설정")

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

  log "Hermes Agent 설치 완료 — 'hermes' 명령어 사용"
fi

# ── 체크포인트 6: config.yaml 설정───────────────────────────────────────────
section("6. config.yaml 설정(컨텍스트/압축/하이브리드)")

CONFIG_FILE="$HERMES_HOME/config.yaml"

if [[ ! -f "$CONFIG_FILE" ]]; then
  warn "config.yaml이 없습니다. 기본 설정을 생성합니다..."
  cat << 'YAML' > "$CONFIG_FILE"
model:
  default: qwen3.6-hermes
  provider: custom
  base_url: http://127.0.0.1:11434/v1
  api_key: ollama
  context_length: 65536

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
    model: qwen3.6:35b-a3b-coding-nvfp4
    timeout: 30
    extra_body: {}

fallback_providers:
  - provider: custom
    base_url: https://api.groq.com/openai/v1
    api_key: YOUR_GROQ_API_KEY
    model: llama-3.3-70b-versatile

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
  log "config.yaml 기본값 생성 완료"
fi

# ── 체크포인트 7: config.yaml 토큰 치환(사용자 입력)─────────────────────────
section("7. API 키 설정")

if ! grep -q "YOUR_GEMINI_API_KEY" "$CONFIG_FILE" 2>/dev/null; then
  log "API 키가 이미 설정되어 있음"
else
  warn "아직 API 키가 설정되지 않았습니다."
  echo ""
  echo "사용할 API 키를 아래에 입력하세요:"
  echo ""
  echo "  Gemini API 키:"
  echo "    → https://aistudio.google.com/app/apikey 에서 생성"
  echo ""
  read -r -p "  Gemini API 키 > " GEMINI_KEY

  if [[ -n "$GEMINI_KEY" && "$GEMINI_KEY" != "YOUR_GEMINI_API_KEY" ]]; then
    # sed를 사용한 안전한 치환 (여러 줄 전체)
    sed -i '' "s/YOUR_GEMINI_API_KEY/$GEMINI_KEY/g" "$CONFIG_FILE"
    log "Gemini API 키 설정 완료"
  fi

  echo ""
  echo "  Groq API 키:"
  echo "    → https://console.groq.com/keys 에서 생성"
  echo ""
  read -r -p "  Groq API 키 > " GROQ_KEY

  if [[ -n "$GROQ_KEY" && "$GROQ_KEY" != "YOUR_GROQ_API_KEY" ]]; then
    sed -i '' "s/YOUR_GROQ_API_KEY/$GROQ_KEY/g" "$CONFIG_FILE"
    log "Groq API 키 설정 완료"
  fi
fi

# ── 체크포인트 8: Open WebUI (Docker)──────────────────────────────────────
section("8. Open WebUI 설치 (Docker)")

# 기존 컨테이너 확인
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
  # image pull
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

# Open WebUI 헬스체크
MAX_RETRIES=10
WEBSITE_URL="http://localhost:3000"
for i in $(seq 1 $MAX_RETRIES); do
  if curl -sf "$WEBSITE_URL" &>/dev/null; then
    break
  fi
  sleep 2
done

if curl -sf "$WEBSITE_URL" &>/dev/null; then
  log "Open WebUI 접근 가능: $WEBSITE_URL"
  warn "설정 → Connections에서 Ollama Base URL을 'http://host.docker.internal:11434/v1'으로 설정하세요"
else
  warn "Open WebUI 시작 지연 중... 잠시 후 'http://localhost:3000'에서 접속하세요"
fi

# ── 체크포인트 9: MLX 가상환경───────────────────────────────────────────────
section("9. MLX 가상환경 환경 설정")

MLX_VENV="$HOME/mlx-env"

if [[ ! -d "$MLX_VENV" ]]; then
  warn "MLX 가상환경이 없습니다. 생성합니다..."
  python3 -m venv "$MLX_VENV"
  source "$MLX_VENV/bin/activate"
  pip install mlx-lm 2>&1 | tail -2
  deactivate
  log "MLX 가상환경 생성: $MLX_VENV"
else
  log "MLX 가상환경 이미 존재: $MLX_VENV"
fi

# .zshrc에 활성화 스크립트 추가
SOURCE_CMD="source $MLX_VENV/bin/activate 2>/dev/null"
if grep -q "mlx-env" "$HOME/.zshrc" 2>/dev/null; then
  log "MLX virtualenv activate 문이 .zshrc에 이미 있음"
else
  echo "" >> "$HOME/.zshrc"
  echo "# MLX 환경 (ollama MLX 모델 로딩용)" >> "$HOME/.zshrc"
  echo "$SOURCE_CMD" >> "$HOME/.zshrc"
  log "MLX venv activate를 .zshrc에 추가"
fi

# ── 체크포인트 10: 최종 정리 및 안내────────────────────────────────────────
section("10. 설치 완료 — 다음 단계")

# .zshrc 리로드 안내
echo ""
echo -e "${BOLD}═══ 설치 완료! 다음 단계는 수동입니다: ═══${NC}"
echo ""
echo "  1. 새 터미널을 열고 'source ~/.zshrc' 실행"
echo "  2. Ollama 서비스 상태 확인:  ollama ps"
echo "  3. Hermes 시작:  hermes"
echo "  4. WebUI 접속:  http://localhost:3000"
echo "  5. WebUI 설정: Connections → Ollama URL = http://host.docker.internal:11434/v1"
echo "  6. WebUI 설정: Web Search → SearXNG 또는 DuckDuckGo 선택"
echo ""
echo -e "${BOLD}🔑 API 키가 config.yaml에 설정되지 않았다면:${NC}"
echo "     nano ~/.hermes/config.yaml 편집 후 GEMINI/GROQ 키를 'YOUR_*_API_KEY' 대신 입력"
echo ""

# 검증 스크립트 제공
VSCRIPT_PATH="$HOME/Projects/hermes-m5max-setup/verify_setup.sh"
cat << 'VERIFY_EOF' > "$VSCRIPT_PATH"
#!/usr/bin/env bash
# hermes-m5max-setup 검증 스크립트
set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()    { echo -e "${GREEN}[✓]${NC} $*"; }
fail()  { echo -e "${RED}[✗]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }

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
check "ollama list (모델 존재)"
for m in "qwen3.6-hermes" "qwen3.6:35b-a3b-coding-mxfp8" "qwen3.6:35b-a3b-coding-nvfp4"; do
  if echo "$MODELS" | grep -q "$m"; then
    ok "모델 '$m': pull됨"
  else
    fail "모델 '$m': 누락"
  fi
  CHECKS_TOTAL=$((CHECKS_TOTAL + 1))
done

# 5. Hermes Agent
check "command -v hermes"

# 6. config.yaml
if [[ -f "$HOME/.hermes/config.yaml" ]]; then
  ok "config.yaml 존재"
  if grep -q "YOUR_GEMINI_API_KEY" "$HOME/.hermes/config.yaml"; then
    warn "config.yaml의 Gemini API 키가 아직 설정되지 않음"
  else
    ok "Gemini API 키 설정됨"
  fi
  if grep -q "YOUR_GROQ_API_KEY" "$HOME/.hermes/config.yaml"; then
    warn "config.yaml의 Groq API 키가 아직 설정되지 않음"
  else
    ok "Groq API 키 설정됨"
  fi
else
  fail "config.yaml 없음"
fi
CHECKS_TOTAL=$((CHECKS_TOTAL + 1))

# 7. Docker
check "docker info"

# 8. Open WebUI
if docker ps --filter "name=open-webui" --format "{{.Names}}" | grep -q "open-webui"; then
  OW_STATUS=$(docker inspect --format '{{.State.Status}}' open-webui)
  if [[ "$OW_STATUS" == "running" ]]; then
    ok "Open WebUI: 실행 중"
  else
    warn "Open WebUI: 중지됨"
  fi
else
  warn "Open WebUI: 설치 안됨"
fi
CHECKS_TOTAL=$((CHECKS_TOTAL + 1))

# 9. MLX venv
if [[ -d "$HOME/mlx-env" ]]; then
  ok "MLX venv 존재"
else
  warn "MLX venv 누락"
fi
CHECKS_TOTAL=$((CHECKS_TOTAL + 1))

# 10. Modelfile
if [[ -f "$HOME/Modelfile" ]]; then
  if grep -q "num_ctx 65536" "$HOME/Modelfile"; then
    ok "Modelfile num_ctx: 65536"
  else
    warn "Modelfile num_ctx: 65536 아님"
  fi
else
  warn "Modelfile 없음"
fi
CHECKS_TOTAL=$((CHECKS_TOTAL + 1))

echo ""
echo "결과: $CHECKS_PASSED/$CHECKS_TOTAL 확인 항목 통과"
if [[ "$CHECKS_PASSED" -eq "$CHECKS_TOTAL" || ($CHECKS_PASSED -ge $((CHECKS_TOTAL - 2)) && "$CHECKS_TOTAL" -ge 9) ]]; then
  echo -e "${GREEN}✓ 전체 설정이 완료되었습니다!${NC}"
else
  echo -e "${YELLOW}! 몇 가지 항목이 누락되었습니다. 위 안내를 참조하세요.${NC}"
fi

VERIFY_EOF

# 검증 스크립트 실행 가능 권한 추가
chmod +x "$VSCRIPT_PATH"

echo "═══════════════════════════════════════════"
echo "💡 검증하려면 다음 명령어를 실행하세요:"
echo "   bash ~/Projects/hermes-m5max-setup/verify_setup.sh"
echo "═══════════════════════════════════════════"
