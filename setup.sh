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
section "0. 시스템 정보 검출"

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

# 메모리 기반 모델/컨텍스트tier 정의 (2026-05-07 최종)
# Mac 구성: Pro(32GB, 48GB), Max(64GB, 128GB)
# qwen3.6:27b-coding-nvfp4 = 4-bit 양자화, 모델 크기 ~20GB
# KV 캐시: ~44KB/token
# 최소 요구: 32GB 미만은 실행 불가
if [[ $TOTAL_RAM_GB -lt 32 ]]; then
      # 16~24GB: M2/M3/M4 Pro — 모델 실행 불가
  err "이 Mac은 ${TOTAL_RAM_GB}GB로 최소 요구사항(32GB)을 만족하지 않습니다."
  err "qwen3.6:27b-coding-nvfp4 모델은 20GB가 필요하므로 최소 32GB RAM이 필수입니다."
  err "설치를 중단합니다."
  exit 1
fi

if [[ $TOTAL_RAM_GB -le 48 ]]; then
      # Pro 32~48GB
  PROFILE="pro"
  HERMES_MODEL="qwen3.6:27b-coding-nvfp4"
  HERMES_CTX=16384
  BACKUP_MODEL="qwen3.6:27b-coding-nvfp4"
  MCP_MODEL="qwen3.6:27b-coding-nvfp4"
  FALLBACK_MODEL="llama-3.3-8b-instruct"
  warn "중용량 프로필: ${HERMES_MODEL} 4-bit (ctx=${HERMES_CTX} — 32~48GB 기준)"

elif [[ $TOTAL_RAM_GB -le 64 ]]; then
       # 49~64GB: M5 Max (64GB 기준)
  PROFILE="max"
  HERMES_MODEL="qwen3.6:35b-a3b-coding-mxfp8"
  HERMES_CTX=131072
  BACKUP_MODEL="qwen3.6:35b-a3b-coding-mxfp8"
  MCP_MODEL="qwen3.6:35b-a3b-coding-nvfp4"
  FALLBACK_MODEL="llama-3.3-70b-versatile"
  log "최적 프로필: ${HERMES_MODEL} (ctx=${HERMES_CTX} — 64GB 기준, 약 83% 사용)"

else
      # 64GB 초과 (96GB, 128GB 이상): M3/M4 Max — 128GB 기준
  PROFILE="max_ultra"
  HERMES_MODEL="qwen3.6:27b-coding-nvfp4"
  HERMES_CTX=262144
  BACKUP_MODEL="qwen3.6:27b-coding-nvfp4"
  MCP_MODEL="qwen3.6:27b-coding-nvfp4"
  FALLBACK_MODEL="llama-3.1-70b-instruct"
  log "최대 프로필: ${HERMES_MODEL} (ctx=${HERMES_CTX} — 128GB 기준, 컨텍스트 최대)"
fi

# 프로필은 32/48/64/128GB 기준으로 맞춰져 있다. 그 외 용량은 구간으로 고른다:
#   ~48GB → pro, 49~64GB → max, 64GB 초과 → max_ultra
case "$TOTAL_RAM_GB" in
  32|48|64|128) ;;
  *) warn "${TOTAL_RAM_GB}GB 는 기준 용량(32/48/64/128GB)이 아니어서 구간에 따라 '$PROFILE' 프로필을 사용합니다. 필요하면 config.yaml 에서 조정하세요." ;;
esac

# ── 체크포인트 1: Python 체크 ─────────────────────────────────────────────
section "1. Python 3 확인"

if ! command -v python3 &>/dev/null; then
  err "Python 3이 설치되어 있지 않습니다. (macOS 기본 Python 3.9+ 또는 pyenv 권장)"
  exit 1
fi

PYVER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
log "Python 버전: $PYVER"

# ── 체크포인트 2: Homebrew & 필수 도구 ────────────────────────────────────────
section "2. Homebrew 및 필수 도구"

if ! command -v brew &>/dev/null; then
  warn "Homebrew가 없습니다. 설치합니다..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install.sh)"
  # Apple Silicon 의 Homebrew 는 /opt/homebrew 에 설치되며, 설치 직후 이 셸의 PATH 에는 없다
  for brew_bin in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [[ -x "$brew_bin" ]]; then
      eval "$("$brew_bin" shellenv)"
      break
    fi
  done
  if ! command -v brew &>/dev/null; then
    err "Homebrew 설치 후에도 brew 명령을 찾을 수 없습니다. 새 터미널에서 다시 실행하세요."
    exit 1
  fi
  log "Homebrew 설치 완료"
else
  log "Homebrew 발견"
fi

brew list jq >/dev/null 2>&1 || brew install jq
brew list yq >/dev/null 2>&1 || brew install yq
log "필수 도구: jq, yq"


# ── 체크포인트 3: Ollama (Homebrew 전용) ──────────────────────────────────────
section "3. Ollama 설치 및 컨텍스트 고정"

if ! command -v ollama &>/dev/null; then
  warn "Ollama가 없습니다. Homebrew로 설치합니다..."
  # cask(앱)가 아니라 formula 로 설치한다 — brew services 는 formula 만 관리할 수 있다
  brew install ollama
  log "Ollama 설치 완료 ($(ollama --version))"
else
  log "Ollama 발견 ($(ollama --version))"
fi

# ollama 에는 health 명령이 없다 → API 가 응답하는지로 실행 여부를 본다
ollama_running() { curl -sf --max-time 2 http://127.0.0.1:11434/api/version >/dev/null; }

wait_for_ollama() {  # 최대 15초 대기
  local _
  for _ in $(seq 1 15); do
    ollama_running && return 0
    sleep 1
  done
  return 1
}

# Ollama 를 brew services 로 관리하는지 (formula 설치) 아니면 앱/직접 실행인지
if brew list --formula ollama &>/dev/null; then
  OLLAMA_VIA_BREW=true
else
  OLLAMA_VIA_BREW=false
fi

# Ollama 를 (다시) 시작한다. $1 = start | restart
start_ollama() {
  if [[ "$OLLAMA_VIA_BREW" == true ]]; then
    brew services "$1" ollama
  elif [[ -d /Applications/Ollama.app ]]; then
    # 앱으로 설치된 경우: brew services 로는 다룰 수 없다
    [[ "$1" == restart ]] && { osascript -e 'quit app "Ollama"' 2>/dev/null || true; sleep 2; }
    open -a Ollama
  else
    warn "Ollama 를 자동으로 시작할 수 없습니다 — 'ollama serve'를 별도 터미널에서 실행하세요"
    return 0
  fi
}

if ! ollama_running; then
  warn "Ollama가 실행 중이 아닙니다. 시작합니다..."
  start_ollama start
  if wait_for_ollama; then
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
  # macOS grep 은 -P 를 지원하지 않는다 → sed 로 "PARAMETER num_ctx <숫자>" 의 숫자를 뽑는다
  MODELF_CHECK=$(ollama show "$HERMES_LABEL" --modelfile 2>/dev/null \
    | sed -nE 's/^PARAMETER[[:space:]]+num_ctx[[:space:]]+([0-9]+).*/\1/p' | head -1 || true)
  MODELF_CHECK="${MODELF_CHECK:-0}"
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
# Ollama 는 ~/.ollama/env 같은 파일을 읽지 않는다. macOS 에서 launchd 로 뜨는 Ollama
# (brew services / 앱) 에 환경변수를 주려면 launchctl setenv 를 써야 한다.
# launchctl setenv 는 재부팅하면 사라지므로, 로그인할 때 다시 설정하고
# Ollama 를 재시작하는 LaunchAgent 도 함께 설치한다.
OLLAMA_ENV_KEEP_ALIVE="-1"
OLLAMA_ENV_CONTEXT_LENGTH="${HERMES_CTX}"
launchctl setenv OLLAMA_KEEP_ALIVE "$OLLAMA_ENV_KEEP_ALIVE"
launchctl setenv OLLAMA_CONTEXT_LENGTH "$OLLAMA_ENV_CONTEXT_LENGTH"
log "Ollama 환경변수 설정 (launchctl): OLLAMA_KEEP_ALIVE=$OLLAMA_ENV_KEEP_ALIVE, OLLAMA_CONTEXT_LENGTH=$OLLAMA_ENV_CONTEXT_LENGTH"

# 로그인 시 재적용: 환경변수 설정 후 Ollama 재시작 (brew 서비스 이름은 버전에 따라 다르다)
if [[ "$OLLAMA_VIA_BREW" == true ]]; then
  OLLAMA_SERVICE_LABEL=$(brew services info ollama --json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)[0].get("service_name") or "")' 2>/dev/null || true)
  OLLAMA_RESTART_CMD="launchctl kickstart -k gui/\$(id -u)/${OLLAMA_SERVICE_LABEL:-homebrew.mxcl.ollama}"
else
  OLLAMA_RESTART_CMD="osascript -e 'quit app \"Ollama\"'; sleep 2; open -a Ollama"
fi
OLLAMA_ENV_AGENT="$HOME/Library/LaunchAgents/com.hermes-m5max-setup.ollama-env.plist"
mkdir -p "$(dirname "$OLLAMA_ENV_AGENT")"
cat << EOF > "$OLLAMA_ENV_AGENT"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.hermes-m5max-setup.ollama-env</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>-c</string>
    <string>launchctl setenv OLLAMA_KEEP_ALIVE ${OLLAMA_ENV_KEEP_ALIVE}; launchctl setenv OLLAMA_CONTEXT_LENGTH ${OLLAMA_ENV_CONTEXT_LENGTH}; sleep 5; $(printf '%s' "$OLLAMA_RESTART_CMD" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
EOF
log "로그인 시 Ollama 환경변수 재적용 LaunchAgent: $OLLAMA_ENV_AGENT"

# 환경변수를 반영하려면 Ollama 를 재시작해야 한다
start_ollama restart

if wait_for_ollama; then
  log "Ollama: 정상 작동 중"
else
  warn "Ollama가 응답하지 않음. 'ollama serve'를 별도 터미널에서 실행하세요."
fi

# ── 체크포인트 4: Hermes Agent ────────────────────────────────────────────
section "4. Hermes Agent 설치"

HERMES_HOME="$HOME/.hermes"

if command -v hermes &>/dev/null; then
  log "Hermes Agent 발견 ($(hermes --version 2>/dev/null || echo 'unknown'))"
else
  warn "Hermes Agent가 없습니다. 공식 설치 스크립트로 설치합니다..."

  # 공식 설치 스크립트는 config.yaml이 없으면 기본 예시로 만든다.
  # 그대로 두면 5단계가 "이미 있음"으로 보고 프로필 맞춤 설정을 건너뛰므로,
  # 설치 전에 없던 파일이면 설치 후 다른 이름으로 치워 둔다.
  config_preexisted=false
  [[ -f "$HERMES_HOME/config.yaml" ]] && config_preexisted=true

  # --non-interactive: 대화형 설정 마법사 생략 (설정은 5단계에서 만든다)
  curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --non-interactive

  if [[ "$config_preexisted" == false && -f "$HERMES_HOME/config.yaml" ]]; then
    mv "$HERMES_HOME/config.yaml" "$HERMES_HOME/config.yaml.installer-default"
    log "설치 스크립트의 기본 config.yaml → config.yaml.installer-default 로 보관"
  fi

  # 설치 스크립트가 ~/.zshrc 에 ~/.local/bin 을 추가하지만, 이 셸에는 아직 반영되지 않는다
  export PATH="$HOME/.local/bin:$PATH"
  if command -v hermes &>/dev/null; then
    log "Hermes Agent 설치 완료 ($(hermes --version 2>/dev/null || echo 'unknown'))"
  else
    err "Hermes Agent 설치 후에도 hermes 명령을 찾을 수 없습니다. ~/.hermes/logs/install.log 를 확인하세요."
    exit 1
  fi
fi

# ── 체크포인트 5: config.yaml ────────────────────────────────────────────
section "5. config.yaml 자동 생성"

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

privacy:
  redact_pii: true
  redact_secrets: true

toolsets:
  - hermes-cli

session_reset:
  mode: both
  idle_minutes: 1440
  at_hour: 4
YAML
  log "config.yaml 생성 완료 — 프로필: $PROFILE (ctx=${HERMES_CTX})"

  # 템플릿에는 설정 버전이 없어 Hermes가 구버전(0)으로 본다 → 최신 형식으로 맞춘다.
  # (custom_providers 가 providers: 로 옮겨지고, 다른 값과 API 키 자리표시는 그대로 유지됨)
  # 새 선택 키를 설정할지 묻는 질문은 stdin 을 막아 기본값(N)으로 넘긴다.
  MIGRATE_LOG="$HERMES_HOME/logs/config-migrate.log"
  mkdir -p "$(dirname "$MIGRATE_LOG")"
  if hermes config migrate </dev/null >"$MIGRATE_LOG" 2>&1; then
    log "config.yaml 최신 형식으로 마이그레이션 완료 ($(grep -m1 'Config version' "$MIGRATE_LOG" | sed 's/^ *//' || echo '버전 정보 없음'))"
  else
    warn "config.yaml 마이그레이션 실패 — 나중에 'hermes config migrate' 를 직접 실행하세요 (로그: $MIGRATE_LOG)"
  fi
else
  # 기존 설정이 있으면 주요 필드만 업데이트
  log "config.yaml이 이미 존재합니다 — 프로필($PROFILE)에 맞게 주요 필드만 업데이트합니다"

  # sed 로 YAML 을 고치면 macOS sed 문법(\d 미지원)이나 현재 값에 따라 조용히 아무것도 안 바뀐다.
  # hermes config set 으로 정확한 키만 바꾼다. 없는 키에 set 하면 엉뚱한 구조가 생기므로
  # (예: fallback_providers 목록 대신 '0': 키) 값이 있을 때만 바꾼다.
  update_config_key() {  # $1 = 키, $2 = 새 값
    local current
    if ! current=$(hermes config get "$1" 2>/dev/null); then
      warn "config.yaml에 $1 항목이 없어 건너뜁니다"
    elif [[ "$current" == "$2" ]]; then
      log "$1 = $2 (변경 없음)"
    elif hermes config set "$1" "$2" >/dev/null 2>&1; then
      log "$1: $current → $2"
    else
      warn "$1 업데이트 실패 — 'hermes config set $1 $2' 를 직접 실행하세요"
    fi
  }

  update_config_key model.context_length "$HERMES_CTX"
  update_config_key fallback_providers.0.model "$FALLBACK_MODEL"
fi

# ── 체크포인트 6: API 키 설정 (대화형) ────────────────────────────────────
section "6. API 키 설정"

if ! grep -q "YOUR_GEMINI_API_KEY" "$CONFIG_FILE" 2>/dev/null; then
  log "API 키가 이미 설정되어 있음"
else
  warn "아직 API 키가 설정되지 않았습니다."

  # 입력한 키를 sed 치환에 그대로 넣으면 / & \ 가 섞인 키에서 치환이 깨진다 → 이스케이프
  escape_sed_replacement() { printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'; }

  echo ""
  echo "아래 API 키들을 입력하세요 (엔터를 치면 건너뜁니다):"
  echo ""
  echo "  Gemini API 키:"
  echo "     → https://aistudio.google.com/app/apikey 에서 생성"
  echo ""
  # -s: 입력하는 키가 화면(과 화면 녹화·공유)에 남지 않게 한다
  read -r -s -p "  Gemini API 키 > " GEMINI_KEY
  echo ""

  if [[ -n "$GEMINI_KEY" && "$GEMINI_KEY" != "YOUR_GEMINI_API_KEY" ]]; then
    sed -i '' "s/YOUR_GEMINI_API_KEY/$(escape_sed_replacement "$GEMINI_KEY")/g" "$CONFIG_FILE"
    log "Gemini API 키 설정 완료"
  else
    warn "Gemini API 키를 건너뜁니다 (~1500 req/일 무료 티어)"
  fi

  echo ""
  echo "  Groq API 키:"
  echo "     → https://console.groq.com/keys 에서 생성"
  echo ""
  read -r -s -p "  Groq API 키 > " GROQ_KEY
  echo ""

  if [[ -n "$GROQ_KEY" && "$GROQ_KEY" != "YOUR_GROQ_API_KEY" ]]; then
    sed -i '' "s/YOUR_GROQ_API_KEY/$(escape_sed_replacement "$GROQ_KEY")/g" "$CONFIG_FILE"
    log "Groq API 키 설정 완료"
  else
    warn "Groq API 키를 건너뜁니다 (~1000 req/일 무료 티어)"
  fi
fi

# ── 체크포인트 7: MLX 가상환경 ────────────────────────────────────────────
section "7. MLX 가상환경"

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

# .zshrc 에서 자동 활성화하지 않는다: 그러면 모든 터미널의 python3/pip 가 이 가상환경 것으로
# 바뀌고, Ollama 는 Python 가상환경이 필요 없다. 쓰는 쪽은 $MLX_VENV/bin/python3 를 직접 부른다.
# 예전 버전이 .zshrc 에 넣은 줄은 사용자 파일이라 지우지 않고 안내만 한다.
if grep -q "source $MLX_VENV/bin/activate" "$HOME/.zshrc" 2>/dev/null; then
  warn ".zshrc 에 MLX 가상환경 자동 활성화 줄이 있습니다 (예전 setup.sh 가 추가)."
  warn "  모든 터미널의 python3/pip 가 바뀌므로, 필요 없으면 이 줄을 지우세요: source $MLX_VENV/bin/activate"
fi
log "MLX 가상환경 사용: source $MLX_VENV/bin/activate (필요할 때만)"

# ── 체크포인트 8: 최종 정리 ────────────────────────────────────────────
section "8. 설치 완료! — 다음 단계"

echo ""
echo -e "${BOLD}═══ 설치가 완료되었습니다! ═══${NC}"
echo ""
echo "  프로필         : $PROFILE"
echo "  주요 모델      : $HERMES_LABEL ($HERMES_MODEL, ${HERMES_CTX} ctx)"
echo "  백업 모델      : $BACKUP_MODEL"
echo "  Ollama URL     : http://localhost:11434/v1"
echo "  Hermes         : hermes"
echo ""
echo -e "${BOLD}수동 작업:${NC}"
echo "   1. 새 터미널: source ~/.zshrc"
echo "   2. Ollama 상태: ollama ps"
echo "   3. Hermes 시작: hermes"
echo ""
echo -e "${BOLD}🔑 API 키 확인:${NC} nano ~/.hermes/config.yaml"
echo ""

# ── 검증 스크립트 생성 ──────────────────────────────────────────────────
# 저장소 위치에 상관없이 setup.sh 옆에 만든다 (curl | bash 로 실행하면 현재 폴더)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" && pwd)"
VSCRIPT_PATH="$SCRIPT_DIR/verify_setup.sh"
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
CPU_MODEL=$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Chip/{print $2; exit}')
echo "  시스템: macOS, ${TOTAL_RAM_GB}GB (${CPU_MODEL:-칩 정보 없음})"
echo ""

# 1. Python
check "python3 --version"

# 2. Ollama
check "command -v ollama"

# 3. Ollama 서비스
if curl -sf --max-time 2 http://127.0.0.1:11434/api/version >/dev/null; then
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
  # grep 으로 읽으면 주석 줄("# context_length: ...")을 먼저 잡는다 → hermes 로 정확한 키를 읽는다
  CTX=$(hermes config get model.context_length 2>/dev/null || echo "설정 안 됨")
  MAIN_MODEL=$(hermes config get model.default 2>/dev/null || echo "설정 안 됨")
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

# 7. MLX venv
if [[ -d "$HOME/mlx-env" ]]; then
  ok "MLX venv 존재"
else
  warn "MLX venv 없음"
fi

# 8. Modelfile num_ctx
MODELF_CTX=$(sed -nE 's/^PARAMETER[[:space:]]+num_ctx[[:space:]]+([0-9]+).*/\1/p' "$HOME/Modelfile" 2>/dev/null | head -1)
if [[ "${MODELF_CTX:-0}" -gt 0 ]]; then
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
echo "  ▶ 검증 실행: bash $VSCRIPT_PATH"
echo ""
