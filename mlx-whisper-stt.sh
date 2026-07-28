#!/bin/zsh
# Hermes STT 커맨드 프로바이더 — mlx-whisper (Metal GPU)
#
# 왜 이게 필요한가:
#   Hermes 내장 local STT 는 faster-whisper(CTranslate2) 기반인데,
#   CTranslate2 에는 Metal 경로가 없어 Apple Silicon 에서 CPU(int8)로만 돈다.
#   같은 large-v3 가중치를 mlx-whisper 로 돌리면 전사 결과는 글자까지 동일한데
#   15.1초 오디오 기준 8.8초 → 0.6초(웜)/1.3초(콜드)로 약 15배 빠르다.
#
# Hermes 연결 (config.yaml):
#   stt:
#     provider: mlx_whisper
#     providers:
#       mlx_whisper:
#         type: command
#         command: <이 스크립트> {input_path} {language}
#         language: ko
#
# 전사 결과는 stdout 으로 출력한다 — Hermes 커맨드 프로바이더는
# {output_path} 파일이 없으면 stdout 을 transcript 로 쓴다.
set -euo pipefail
export HF_HUB_DISABLE_PROGRESS_BARS=1

AUDIO="$1"
LANG_CODE="${2:-ko}"

exec /Users/sungjunmaing/mlx-env/bin/python3 - "$AUDIO" "$LANG_CODE" <<'EOF'
import sys
import mlx_whisper

result = mlx_whisper.transcribe(
    sys.argv[1],
    path_or_hf_repo="mlx-community/whisper-large-v3-mlx",
    language=sys.argv[2],
)
print(result["text"].strip())
EOF
