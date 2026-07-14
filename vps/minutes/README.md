# minutes（議事録生成サービス）VPS版 雛形 — Step 2（CLI）

AI-OCR用VPS（NixOS）の `~/projects/minutes/` に配置して動かす、議事録生成の
自己完結パイプラインです。設計書「議事録自動化_サーバー化設計書.md」の Step 2
（方式A・CLI起点・完全フォルダ内）に対応します。

## 方針・制約
- ツール（python・ffmpeg・requests）は**この flake の中だけ**で用意し、
  サーバー全体（グローバル）には何も足しません。
- 秘密情報は**環境変数のみ**（`SAKURA_AI_TOKEN` / `BACKLOG_API_KEY`）。
- 文字起こしも下書き生成も**さくらのAI Engine**を使用（国内完結・承認済み）。
- **公開前チェックとBacklog登録は含めません**（draft まで）。

## VPSへの配置
このフォルダ（`vps/minutes/` の中身）を VPS の `~/projects/minutes/` に置きます。
```bash
# 例：PCから scp（tcs-ocr は ~/.ssh/config のエイリアス）
scp -r vps/minutes/* tcs-ocr:~/projects/minutes/
```

## セットアップ（VPS上・初回）
```bash
ssh tcs-ocr
cd ~/projects/minutes
export SAKURA_AI_TOKEN='<UUID>:<secret>'   # 環境変数のみ（ファイルに置かない）
nix develop            # python + ffmpeg が入ったシェルに入る（初回は取得に時間）
nix flake lock         # flake.lock を作成（再現性のため）
```

## 実行（下書き生成）
```bash
# devshell 内で：
python -m src.main draft inbox/xxx.mp4 --vtt inbox/xxx.vtt --no 4

# もしくは一発（flake app）：
nix run .#minutes -- draft inbox/xxx.mp4 --vtt inbox/xxx.vtt --no 4
```
出力：`out/minutes.md`（この後、人が公開前チェック → Backlog登録）。

主なオプション：
- `--vtt <path>` Teams字幕。あると登壇者が自動で入り、whisperと突き合わせ。
- `--no <N>` 会議番号（未指定は「要確認」。Backlog自動採番は今後移植）。
- `--date YYYY/MM/DD` 開催日の上書き（既定は録画ファイル名の日時から）。
- `--fid <fFID>` Cybozu録画の直リンクを組み立て（`REC_FILE_URL_TEMPLATE`）。数字のみ。
- `--link <URL>` 録画リンクを完全URLで上書き。優先順位は `--link` > `--fid` > 既定（共有フォルダURL）。

## 構成
```
~/projects/minutes/
  flake.nix / flake.lock     依存（python+requests, ffmpeg）を内包
  src/
    config.py                設定（環境変数・モデル名・上限）
    sakura.py                さくらAI Engine（chat / transcribe）
    vtt.py                   Teams .vtt 解析（話者正規化・alias）
    audio.py                 ffmpeg 抽出＋無音分割（30分/30MB対策）
    prompt.py                2ソースのプロンプト組立
    main.py                  CLI（draft）
  prompts/prompt_template.txt  PC版と共通のテンプレート
  speaker_aliases.txt          話者名の上書き
  inbox/ work/ out/            入力／作業／出力
```

## 未実装（今後 / Step 3 以降）
- 会議番号のBacklog自動採番（`Get-BacklogMeetingNo` の移植）。
- `register.py`（承認後のBacklog Document API登録）。
- ジョブ/状態管理（`jobstore.py`）・クォータ台帳（`quota.py`）・非同期実行。
- 入口 `server.py`（FastAPI・トークン認証）＋ Caddy(443)。※管理者OK後（Step 3）。
- チャンク境界のオーバーラップ＆重複除去（現状は無音分割のみ）。
- LLMのコンテキスト上限対策（超長時間会議の分割要約）。

## 注意
- 音声・文字起こしはさくらのAI Engine（承認済み・国内完結・学習利用なし）へ送信されます。
- `inbox/ work/ out/` の中身（社内情報）は外部同期される場所に置かないでください。
