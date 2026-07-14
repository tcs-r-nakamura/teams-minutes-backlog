"""CLI entry point (Step 2: run on the VPS via SSH).

  python -m src.main draft <audio> [--vtt <teams.vtt>] [options]

Pipeline (all on the VPS, using Sakura AI Engine):
  1. extract audio (ffmpeg) -> mp3
  2. split into <=30min chunks at silence -> transcribe each (Sakura Whisper) -> join
  3. parse Teams .vtt (if given) -> speaker-labelled text + speaker list
  4. build the 2-source prompt from the template
  5. generate the draft (Sakura Chat, gpt-oss-120b) -> out/minutes.md

Backlog registration and the human pre-publication check are intentionally NOT
done here (draft only).
"""
import argparse
import os
import re
import sys

from . import audio, backlog, config, prompt, sakura, vtt


def cmd_draft(args):
    os.makedirs(config.WORK_DIR, exist_ok=True)
    os.makedirs(config.OUT_DIR, exist_ok=True)

    date, _token = prompt.date_from_filename(os.path.basename(args.audio))
    meeting_date = args.date or date or "要確認"

    # Meeting number: use --no if given, else auto from Backlog (max 第N回 + 1;
    # reuse the sibling's number if this date is already there). Falls back to
    # "要確認" if Backlog cannot be reached / not configured.
    meeting_no = args.no
    if meeting_no == "要確認":
        date8 = re.sub(r"[^0-9]", "", meeting_date) if meeting_date else ""
        bl = backlog.meeting_no(date8 if len(date8) == 8 else None)
        if bl is not None:
            meeting_no = str(bl)
            print("[info] meeting number from Backlog: 第%s回" % meeting_no, flush=True)
        else:
            print("[info] meeting number not auto-resolved; leaving as '要確認'.", flush=True)

    # 1-2) transcription via Sakura Whisper (extract -> split -> transcribe -> join)
    whisper_text = ""
    if args.audio:
        print("[1/4] extracting audio ...", flush=True)
        mp3 = os.path.join(config.WORK_DIR, "audio.mp3")
        audio.extract_audio(args.audio, mp3)
        print("[2/4] splitting + transcribing (Sakura Whisper) ...", flush=True)
        chunks, flagged = audio.split_audio(mp3, os.path.join(config.WORK_DIR, "chunks"))
        parts = []
        for i, c in enumerate(chunks):
            print("      chunk %d/%d ..." % (i + 1, len(chunks)), flush=True)
            parts.append(sakura.transcribe(c))
        whisper_text = "\n".join(p.strip() for p in parts).strip()
        if flagged:
            print("[WARN] a chunk boundary used a fixed time (no silence found); "
                  "check the transcript seam.", file=sys.stderr)

    # 3) Teams transcript
    teams_text = ""
    speakers = []
    chars = {}
    if args.vtt:
        if not vtt.is_teams_vtt(args.vtt):
            print("[WARN] %s does not look like a Teams WEBVTT; ignoring." % args.vtt,
                  file=sys.stderr)
        else:
            aliases = vtt.load_aliases(args.aliases)
            teams_text, speakers, chars = vtt.parse(args.vtt, aliases)
            print("[3/4] Teams transcript: %d speakers" % len(speakers), flush=True)

    # 登壇者 = the single person who spoke the most (by total characters).
    # Everyone else stays in the transcript body but is not listed as 登壇者.
    # No Teams transcript -> leave it empty and let the template decide.
    speaker_field = ""
    if speakers:
        top = max(speakers, key=lambda s: chars.get(s, 0))  # ties -> first appearance
        speaker_field = top
        others = [s for s in speakers if s != top]
        print("      登壇者(発言最多): %s (%d字)%s"
              % (top, chars.get(top, 0),
                 ("／他は本文のみ: " + ", ".join(others)) if others else ""),
              flush=True)

    # 4) build prompt + generate draft
    with open(args.template, encoding="utf-8") as f:
        template = f.read()
    rec_link = args.link or config.REC_FOLDER_URL
    p = prompt.build(template, meeting_no, meeting_date, rec_link, speaker_field,
                     teams_text, whisper_text)
    print("[4/4] generating draft (Sakura Chat, model=%s) ..." % config.CHAT_MODEL, flush=True)
    content = prompt.strip_code_fence(sakura.chat(p, model=config.CHAT_MODEL))
    if not content.strip():
        print("[ERROR] empty response from the model.", file=sys.stderr)
        return 1

    out_path = args.out or os.path.join(config.OUT_DIR, "minutes.md")
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(content)
    print("saved: %s (%d chars)" % (out_path, len(content)))
    print("next : human pre-publication review, then register to Backlog.")
    return 0


def _title_from_md(content):
    """First level-1 heading (# ...), ignoring fenced code blocks."""
    in_fence = False
    for line in content.splitlines():
        if re.match(r"^\s*(```|~~~)", line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        m = re.match(r"^\s*#\s+(.+?)\s*#*\s*$", line)
        if m:
            return m.group(1).strip()
    return None


def cmd_register(args):
    """Register a human-reviewed minutes .md to Backlog (draft -> check -> here)."""
    md = args.md or os.path.join(config.OUT_DIR, "minutes.md")
    if not os.path.exists(md):
        print("[ERROR] minutes not found: %s" % md, file=sys.stderr)
        return 1
    with open(md, encoding="utf-8") as f:
        content = f.read()
    if not content.strip():
        print("[ERROR] minutes is empty: %s" % md, file=sys.stderr)
        return 1
    title = args.title or _title_from_md(content) or os.path.splitext(os.path.basename(md))[0]

    print("=== register to Backlog ===")
    print("  file  : %s" % md)
    print("  title : %s" % title)
    print("  space : %s   project: %s" % (config.BACKLOG_SPACE, config.BACKLOG_PROJECT_ID))
    print("  body  : %d chars" % len(content))

    dup = backlog.find_duplicate(title)
    if dup is True:
        print("[DUPLICATE] a document titled '%s' already exists under the parent; "
              "not registering." % title, file=sys.stderr)
        return 1
    if dup is None:
        # fail closed: the safety check could not run.
        if not args.allow_unchecked:
            print("[ERROR] duplicate check could not run (Backlog unreachable / "
                  "misconfigured). Aborting. Re-run with --allow-unchecked to override.",
                  file=sys.stderr)
            return 1
        print("[WARN] duplicate check skipped (--allow-unchecked).", file=sys.stderr)

    # Numbering collision: a different sibling already using this '第N回'.
    conflict = backlog.number_conflict(title)
    if conflict:
        print("[NUMBER CONFLICT] this title's 第N回 is already used by a different "
              "document: '%s'. Fix the number before registering." % conflict, file=sys.stderr)
        if not args.allow_unchecked:
            return 1
        print("[WARN] proceeding despite number conflict (--allow-unchecked).", file=sys.stderr)

    if args.dry_run:
        print("[DRY RUN] not sending.")
        return 0
    if not args.force:
        ans = input("Register to %s ? type 'y' to proceed: " % config.BACKLOG_SPACE)
        if ans.strip().lower() != "y":
            print("[ABORTED] not sending.")
            return 0
    try:
        res = backlog.create_document(title, content)
    except Exception as e:
        print("[ERROR] Backlog API call failed: %s" % e, file=sys.stderr)
        return 1
    print("=== registered ===")
    print("  document id : %s" % res.get("id"))
    print("  title       : %s" % res.get("title"))
    print("  -> open Backlog and verify.")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="minutes")
    sub = ap.add_subparsers(dest="cmd", required=True)

    d = sub.add_parser("draft", help="transcribe + generate a minutes draft")
    d.add_argument("audio", help="recording file (.mp4/.wav/.mp3/...)")
    d.add_argument("--vtt", default=None, help="Teams transcript (.vtt), optional")
    d.add_argument("--no", default="要確認", help="meeting number (default: 要確認)")
    d.add_argument("--date", default=None, help="override meeting date YYYY/MM/DD")
    d.add_argument("--link", default=None, help="override recording link")
    d.add_argument("--template", default=config.PROMPT_TEMPLATE)
    d.add_argument("--aliases", default=config.SPEAKER_ALIASES)
    d.add_argument("--out", default=None, help="output .md path")
    d.set_defaults(func=cmd_draft)

    r = sub.add_parser("register", help="register a reviewed minutes .md to Backlog")
    r.add_argument("--md", default=None, help="minutes .md (default: out/minutes.md)")
    r.add_argument("--title", default=None, help="override title (default: first # heading)")
    r.add_argument("--dry-run", action="store_true", help="check only, do not send")
    r.add_argument("--force", action="store_true", help="skip the confirm prompt")
    r.add_argument("--allow-unchecked", action="store_true",
                   help="proceed even if the duplicate check could not run, "
                        "OR a number conflict was detected (safety override; use with care)")
    r.set_defaults(func=cmd_register)

    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
