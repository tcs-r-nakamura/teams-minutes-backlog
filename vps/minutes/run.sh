#!/usr/bin/env bash
# run.sh — 便利ラッパー。inbox/ の録画と字幕を自動で拾って draft を1コマンドで実行する。
#
# 使い方（nix develop に入った状態で、~/projects/minutes 直下で）:
#   ./run.sh                 # inbox/ の録画+字幕から下書き生成
#   ./run.sh --date 2026/07/03   # draft への追加オプションはそのまま渡せる
#   ./run.sh --no 5
#
# これは draft だけを実行する。register は out/minutes.md を人がチェックした後に
# 別途 `python -m src.main register` を実行すること（自動化しない）。
set -euo pipefail

cd "$(dirname "$0")"   # src/ とテンプレートを参照するため、必ずプロジェクト直下で実行

shopt -s nullglob
recs=(inbox/*.mp4 inbox/*.mov inbox/*.mkv inbox/*.wav inbox/*.mp3 inbox/*.m4a)
vtts=(inbox/*.vtt)

if [ ${#recs[@]} -eq 0 ]; then
  echo "[ERROR] inbox/ に録画ファイル(.mp4 等)がありません。scp で置いてから実行してください。" >&2
  exit 1
fi
if [ ${#recs[@]} -gt 1 ]; then
  echo "[ERROR] inbox/ に録画が複数あります。1つだけ残すか、手動で" >&2
  echo "        python -m src.main draft <録画> [--vtt <字幕>] を実行してください:" >&2
  printf '  %s\n' "${recs[@]}" >&2
  exit 1
fi
rec="${recs[0]}"

vtt_opt=()
if [ ${#vtts[@]} -eq 1 ]; then
  vtt_opt=(--vtt "${vtts[0]}")
elif [ ${#vtts[@]} -gt 1 ]; then
  echo "[ERROR] inbox/ に字幕(.vtt)が複数あります。1つだけ残してください:" >&2
  printf '  %s\n' "${vtts[@]}" >&2
  exit 1
else
  echo "[WARN] inbox/ に字幕(.vtt)がありません。whisper のみで下書きします（登壇者は空欄）。" >&2
fi

echo "[run] draft: ${rec} ${vtt_opt[*]:-（字幕なし）}"
python -m src.main draft "${rec}" "${vtt_opt[@]}" "$@"

# draft が成功した時だけ（set -e により失敗時はここに来ない）、使った入力を
# processed/ へ退避する。次の会議のために inbox を自動で空にするのが目的。
# 削除ではなく移動。PC/サイボウズに原本があるのでこれ自体が最終保管ではない。
# 日時プレフィックスで退避先を一意化（同名録画の再実行でも上書きしない＝後から参照可）。
archive="processed/$(date +%Y%m%d_%H%M%S)_$(basename "${rec%.*}")"
mkdir -p "${archive}"
if [ ${#vtts[@]} -eq 1 ]; then
  mv -f "${rec}" "${vtts[0]}" "${archive}/"   # 録画+字幕をまとめて移動（部分退避を避ける）
else
  mv -f "${rec}" "${archive}/"
fi
echo "[done] 使った入力を ${archive}/ へ移動しました（inbox は次の会議用に空になりました）。"

echo
echo "[next] out/minutes.md を人がチェック・修正 → 問題なければ登録:"
echo "         python -m src.main register --dry-run   # まず確認（送らない）"
echo "         python -m src.main register             # 本登録（y で送信）"
