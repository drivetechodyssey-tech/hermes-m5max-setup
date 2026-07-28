#!/bin/zsh
# Hermes 로그 회전 — launchd가 관리하는 로그용
#
# 왜 필요한가:
#   config.yaml 의 logging.max_size_mb / backup_count 는 Python 로거가 쓰는
#   agent.log · errors.log 에만 적용된다. gateway.log 와 gateway.error.log 는
#   launchd 가 StandardOutPath / StandardErrorPath 로 직접 리다이렉트하는
#   파일이라 그 규칙 밖에 있고, 무한정 자란다.
#
# 왜 copytruncate 인가:
#   게이트웨이 프로세스가 이 파일들을 fd 로 붙들고 있다. mv 로 옮기면
#   프로세스는 이동된 inode 에 계속 쓰므로 새 파일은 영영 비어 있고
#   로그는 옮겨진 파일로 들어간다. 내용을 복사한 뒤 원본을 제자리에서
#   비우면(: > file) fd 가 유지되어 재시작 없이 회전된다.

set -u

LOG_DIR="$HOME/.hermes/logs"
MAX_BYTES=$(( 5 * 1024 * 1024 ))   # 5MB — config.yaml logging.max_size_mb 와 맞춤
KEEP=3                              # backup_count 와 맞춤

# launchd 가 관리해서 자체 회전이 안 되는 파일들
TARGETS=(
  "gateway.error.log"
  "gateway.log"
  "desktop.log"
  "gui.log"
)

rotated=0

for name in $TARGETS; do
  f="$LOG_DIR/$name"
  [[ -f "$f" ]] || continue

  size=$(stat -f%z "$f" 2>/dev/null || echo 0)
  (( size > MAX_BYTES )) || continue

  # 오래된 세대를 뒤로 밀기: .2.gz → .3.gz, .1.gz → .2.gz
  i=$KEEP
  while (( i > 1 )); do
    [[ -f "$f.$((i-1)).gz" ]] && mv -f "$f.$((i-1)).gz" "$f.$i.gz"
    (( i-- ))
  done

  # 현재 내용을 .1 로 복사한 뒤 원본을 제자리에서 비운다 (fd 유지)
  if cp "$f" "$f.1" 2>/dev/null; then
    : > "$f"
    gzip -f "$f.1" 2>/dev/null
    printf '%s  회전: %s (%.1f MB)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$name" "$(( size ))e-6"
    rotated=$((rotated+1))
  else
    printf '%s  실패: %s 를 복사할 수 없음\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$name" >&2
  fi

  # KEEP 세대를 넘어가는 것 제거
  for old in "$f".*.gz; do
    [[ -f "$old" ]] || continue
    n="${old##*.log.}"; n="${n%%.gz}"
    [[ "$n" =~ '^[0-9]+$' ]] && (( n > KEEP )) && rm -f "$old"
  done
done

exit 0
