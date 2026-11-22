#!/usr/bin/env python3
"""Voice and assembly of the demo video (.github/workflows/video.yml). Standard library; runs ffmpeg, ffprobe and
the chosen voice engine.

    video-make.py voice RESOLVED VOICE_DIR --engine edge|espeak|none [--edge-voice NAME]
    video-make.py build RESOLVED VOICE_DIR CAPTURE_DIR OUT_DIR [--dry-run]

voice: speaks each shot's caption, which is also its voice line (video/script.json is the one source; a few rules
  turn "$85.9M" into "85.9 million dollars", "+2 s" into "plus 2 seconds" and apply the script's pronunciations).
  One voice for the whole video: edge-tts (its command in EDGE_TTS), espeak-ng, or none (captions only, timed for
  reading). A line that fails three times stops the run, so a video never mixes two voices. Each line's length is
  measured with ffprobe and written to VOICE_DIR/timings.json.
build: lays the shots out (a shot lasts its planned seconds, longer when its line needs it; a realtime capture is
  never cut and plays at the speed it was captured), writes captions.ass (captions, labels, the clock of real-time
  shots and the synthetic-voice tag, all burnt in) and captions.srt (captions only, for an upload's caption track),
  encodes one clip per shot and the voice track, joins them at 1920x1080, 30 fps, H.264 + AAC with the loudness
  normalised to -16 LUFS, checks the file (length under limits.maxSeconds, size, frame rate, codecs) and makes
  contact-sheet.png with one frame every 5 s. The length limit is checked on the plan, after the voice is measured,
  and on the finished file. --dry-run stops before ffmpeg: layout, captions and timeline only.
"""

import argparse
import json
import math
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
W, H, FPS = 1920, 1080, 30
LEAD, TAIL = 0.35, 0.6          # silence before and after a voice line inside its shot
READ_CPS = 15.0                 # characters per second a viewer reads, for captions without a voice
CHUNK = 92                      # longest caption on screen at once (two lines at the caption size)
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
SCALE = {"K": "thousand", "M": "million", "B": "billion"}
MID_DOT, TIMES = chr(0xB7), chr(0xD7)
NAVY_BOX, SEA_BOX = "&H1A4A1A11", "&H206C7E16"   # ASS colours are &HAABBGGRR


def die(msg):
    print(f"video-make: {msg}")
    sys.exit(1)


def load(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def ffmpeg(args, cwd=None):
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-y", *[str(a) for a in args]]
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if r.returncode != 0:
        die(f"ffmpeg failed ({r.returncode}): {' '.join(cmd)[:600]}\n{r.stderr.strip()[-2000:]}")
    return r


def probe(path):
    r = subprocess.run(["ffprobe", "-v", "error", "-show_entries",
                        "format=duration:stream=codec_type,codec_name,width,height,r_frame_rate,sample_rate",
                        "-of", "json", str(path)], capture_output=True, text=True)
    if r.returncode != 0:
        die(f"ffprobe could not read {path}: {r.stderr.strip()[-400:]}")
    return json.loads(r.stdout)


def seconds_of(path):
    return float(probe(path)["format"]["duration"])


# ---------- voice ----------

def unit(n):
    return "second" if n == "1" else "seconds"


def spoken(text, pronounce):
    t = re.sub(r"\$(\d+(?:\.\d+)?)([KMB])\b", lambda m: f"{m.group(1)} {SCALE[m.group(2)]} dollars", text)
    t = re.sub(r"\+(\d+) s\b", lambda m: f"plus {m.group(1)} {unit(m.group(1))}", t)
    t = re.sub(r"(?<![\w.])(\d+) s\b", lambda m: f"{m.group(1)} {unit(m.group(1))}", t)
    for word, say in pronounce.items():
        t = re.sub(r"(?<!\w)" + re.escape(word) + r"(?!\w)", say, t)
    t = t.replace(TIMES, " times ").replace(MID_DOT, ",")
    return re.sub(r"\s+", " ", t).strip()


def tts(engine, text, out, settings, edge_voice):
    if engine == "edge":
        exe = os.environ.get("EDGE_TTS") or shutil.which("edge-tts")
        if not exe:
            die("edge-tts is not installed (EDGE_TTS unset)")
        cmd = [exe, "--voice", edge_voice, f"--rate={settings.get('edgeRate', '+0%')}", "--text", text,
               "--write-media", str(out)]
    else:
        cmd = ["espeak-ng", "-v", settings.get("espeakVoice", "en-us"), "-s", str(settings.get("espeakSpeed", 160)),
               "-w", str(out), text]
    last = ""
    for attempt in range(1, 4):
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
        except subprocess.TimeoutExpired:
            last = "no answer within 180 s"
            print(f"{engine} attempt {attempt} failed: {last}")
            time.sleep(3 * attempt)
            continue
        if r.returncode == 0 and out.is_file() and out.stat().st_size > 1000:
            return
        last = (r.stderr or r.stdout).strip()[-400:]
        print(f"{engine} attempt {attempt} failed: {last}")
        time.sleep(3 * attempt)
    die(f"{engine} failed three times on one line ({last}). A video never mixes voices, so this run stops: "
        "dispatch again, or choose voice espeak or none")


def cmd_voice(a):
    res = load(a.resolved)
    out = Path(a.voice_dir)
    out.mkdir(parents=True, exist_ok=True)
    settings = res["voice"]
    pron = settings.get("pronounce", {})
    if a.engine == "edge" and not re.fullmatch(r"en-US-[A-Za-z]+Neural", a.edge_voice or ""):
        die("edge voice must look like en-US-<Name>Neural")
    lines = {}
    for s in res["shots"]:
        say = spoken(s["caption"], pron)
        if a.engine == "none":
            lines[s["id"]] = {"file": None, "seconds": round(max(1.5, len(s["caption"]) / READ_CPS), 3), "spoken": say}
            continue
        f = out / f"{s['id']}.{'mp3' if a.engine == 'edge' else 'wav'}"
        tts(a.engine, say, f, settings, a.edge_voice)
        lines[s["id"]] = {"file": f.name, "seconds": round(seconds_of(f), 3), "spoken": say}
        print(f"{s['id']} {lines[s['id']]['seconds']:6.2f} s  {say[:90]}")
    voice_name = {"edge": a.edge_voice, "espeak": settings.get("espeakVoice", "en-us"), "none": None}[a.engine]
    (out / "timings.json").write_text(json.dumps({"engine": a.engine, "voice": voice_name, "lines": lines},
                                                 indent=2) + "\n", encoding="utf-8")
    need = sum(LEAD + x["seconds"] + TAIL for x in lines.values())
    print(f"voice: {a.engine} {voice_name or ''}, {len(lines)} lines, {sum(x['seconds'] for x in lines.values()):.1f} s "
          f"spoken ({need:.1f} s with pauses)")


# ---------- layout and captions ----------

def layout(res, timings):
    t = 0.0
    rows = []
    for s in res["shots"]:
        line = timings["lines"].get(s["id"])
        if line is None:
            die(f"{s['id']}: no voice line timing")
        d = max(float(s["seconds"]), LEAD + float(line["seconds"]) + TAIL)
        cap = s.get("capture") or {}
        if s["type"] == "realtime":
            d = max(d, float(cap.get("captureSeconds", s.get("captureSeconds", 0))))
        if s["type"] == "scroll":
            d = max(d, sum(float(f["d"]) for f in cap.get("frames", [])) + 0.5)
        d = math.ceil(d * FPS - 1e-6) / FPS
        rows.append({"id": s["id"], "type": s["type"], "start": round(t, 3), "dur": round(d, 3),
                     "voice": float(line["seconds"]), "planned": float(s["seconds"])})
        t += d
    return rows, round(t, 3)


def split_long(s):
    """Halve a sentence longer than CHUNK at the space nearest its middle, preferring one after , ; or :."""
    if len(s) <= CHUNK:
        return [s]
    target = len(s) / math.ceil(len(s) / CHUNK)
    bonus = target / 2 + 2
    best = None
    for i, ch in enumerate(s):
        if ch != " " or i < 16 or len(s) - i < 12:
            continue
        score = abs(i - target) - (bonus if s[i - 1] in ",;:" else 0)
        if best is None or score < best[0]:
            best = (score, i)
    i = best[1] if best else CHUNK
    return split_long(s[:i].strip()) + split_long(s[i:].strip())


def chunks(text):
    parts = []
    for sentence in re.split(r"(?<=[.!?])\s+", text.strip()):
        if sentence:
            parts += split_long(sentence)
    return parts


def caption_events(res, rows, timings):
    """(start, end, text) for every caption on screen, timed over the measured length of its voice line."""
    out = []
    for s, r in zip(res["shots"], rows):
        parts = chunks(s["caption"])
        span = float(timings["lines"][s["id"]]["seconds"])
        t0 = r["start"] + LEAD
        weights = [max(len(p), 12) for p in parts]
        total = float(sum(weights))
        t = t0
        for p, w in zip(parts, weights):
            d = span * w / total
            out.append((t, min(t + d, r["start"] + r["dur"]), p))
            t += d
    return out


def ass_time(t):
    cs = max(0, int(round(t * 100)))
    h, cs = divmod(cs, 360000)
    m, cs = divmod(cs, 6000)
    s, cs = divmod(cs, 100)
    return f"{h}:{m:02d}:{s:02d}.{cs:02d}"


def ass_text(s):
    return s.replace("\\", "/").replace("{", "(").replace("}", ")").replace("\n", " ")


def srt_time(t):
    ms = max(0, int(round(t * 1000)))
    h, ms = divmod(ms, 3600000)
    m, ms = divmod(ms, 60000)
    s, ms = divmod(ms, 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


def write_captions(res, rows, timings, total, out):
    caps = caption_events(res, rows, timings)
    head = [
        "[Script Info]", "ScriptType: v4.00+", f"PlayResX: {W}", f"PlayResY: {H}", "WrapStyle: 0",
        "ScaledBorderAndShadow: yes", "YCbCr Matrix: TV.709", "",
        "[V4+ Styles]",
        "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, "
        "Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, "
        "MarginR, MarginV, Encoding",
        f"Style: Caption,DejaVu Sans,46,&H00FFFFFF,&H00FFFFFF,{NAVY_BOX},{NAVY_BOX},0,0,0,0,100,100,0,0,3,14,0,2,180,180,52,1",
        f"Style: Label,DejaVu Sans,30,&H00FFFFFF,&H00FFFFFF,{NAVY_BOX},{NAVY_BOX},0,0,0,0,100,100,0,0,3,10,0,7,40,600,36,1",
        f"Style: Tag,DejaVu Sans,26,&H00FFFFFF,&H00FFFFFF,{SEA_BOX},{SEA_BOX},0,0,0,0,100,100,0,0,3,9,0,9,1300,40,36,1",
        "",
        "[Events]",
        "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text",
    ]
    ev = []
    for a, b, text in caps:
        ev.append(f"Dialogue: 2,{ass_time(a)},{ass_time(b)},Caption,,0,0,0,,{ass_text(text)}")
    for s, r in zip(res["shots"], rows):
        label = s.get("label")
        if not label:
            continue
        a, end = r["start"], r["start"] + r["dur"]
        if s.get("clock"):
            live = float((s.get("capture") or {}).get("captureSeconds", s.get("captureSeconds", 0)) or 0)
            steps = int(min(live, r["dur"]) * 10)
            for k in range(steps):
                t = k / 10
                ev.append(f"Dialogue: 1,{ass_time(a + t)},{ass_time(a + t + 0.1)},Label,,0,0,0,,"
                          f"{ass_text(label)}   {int(t // 60)}:{t % 60:04.1f}")
            a = a + steps / 10
        if a < end:
            ev.append(f"Dialogue: 1,{ass_time(a)},{ass_time(end)},Label,,0,0,0,,{ass_text(label)}")
    if timings["engine"] != "none":
        ev.append(f"Dialogue: 1,{ass_time(0)},{ass_time(total)},Tag,,0,0,0,,{ass_text(res['voice']['tag'])}")
    (out / "captions.ass").write_text("\n".join(head + ev) + "\n", encoding="utf-8")
    srt = []
    for i, (a, b, text) in enumerate(caps, 1):
        srt += [str(i), f"{srt_time(a)} --> {srt_time(b)}", text, ""]
    (out / "captions.srt").write_text("\n".join(srt), encoding="utf-8")
    return len(caps)


# ---------- clips and assembly ----------

VF = (f"scale={W}:{H}:force_original_aspect_ratio=decrease:flags=lanczos,"
      f"pad={W}:{H}:(ow-iw)/2:(oh-ih)/2:color=0xf6f6f8,setsar=1,format=yuv420p")
ENC = ["-c:v", "libx264", "-preset", "veryfast", "-crf", "12", "-r", str(FPS), "-an"]


def preflight():
    for tool in ("ffmpeg", "ffprobe"):
        if not shutil.which(tool):
            die(f"{tool} is not installed")
    filters = subprocess.run(["ffmpeg", "-hide_banner", "-filters"], capture_output=True, text=True).stdout
    encoders = subprocess.run(["ffmpeg", "-hide_banner", "-encoders"], capture_output=True, text=True).stdout
    missing = [f for f in ("subtitles", "loudnorm", "drawtext", "tile", "tpad", "concat", "adelay", "apad")
               if not re.search(r"\s" + f + r"\s", filters)]
    missing += [e for e in ("libx264", "aac") if not re.search(r"\s" + e + r"\s", encoders)]
    if missing:
        die(f"this ffmpeg lacks {', '.join(missing)}")


def concat_list(path, items):
    """items: (absolute file, seconds). The last file is repeated, as the concat demuxer ignores its duration."""
    lines = ["ffconcat version 1.0"]
    for f, d in items:
        lines += [f"file '{str(f)}'", f"duration {max(d, 1 / FPS):.4f}"]
    lines.append(f"file '{str(items[-1][0])}'")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def clip_for(s, r, cap_dir, work):
    out = work / f"{s['id']}.mp4"
    d = f"{r['dur']:.3f}"
    cap = s.get("capture") or {}
    src = cap_dir / s["id"]
    if s["type"] in ("still", "zoom", "card"):
        files = cap.get("files") or []
        if not files:
            die(f"{s['id']}: no captured image")
        ffmpeg(["-loop", "1", "-framerate", FPS, "-i", src / files[0], "-t", d, "-vf", VF, *ENC, out])
    elif s["type"] in ("scroll", "realtime"):
        frames = cap.get("frames") or []
        if not frames:
            die(f"{s['id']}: no captured frames")
        if s["type"] == "realtime":
            ts = [float(f["t"]) for f in frames]
            end = float(cap.get("captureSeconds", s.get("captureSeconds")))
            durs = [b - a for a, b in zip(ts, ts[1:])] + [max(1 / FPS, end - ts[-1])]
            if ts[0] > 0:
                durs[0] += ts[0]
        else:
            durs = [float(f["d"]) for f in frames]
        lst = work / f"{s['id']}.ffconcat"
        concat_list(lst, [((src / f["file"]).resolve(), dd) for f, dd in zip(frames, durs)])
        ffmpeg(["-f", "concat", "-safe", "0", "-i", lst,
                "-vf", f"fps={FPS},{VF},tpad=stop_mode=clone:stop_duration={d}", "-t", d, *ENC, out])
    elif s["type"] == "clip":
        ffmpeg(["-i", ROOT / s["file"], "-vf", f"fps={FPS},{VF},tpad=stop_mode=clone:stop_duration={d}", "-t", d,
                *ENC, out])
    else:
        die(f"{s['id']}: unknown type {s['type']}")
    return out


def audio_for(s, r, voice_dir, timings, work):
    out = work / f"{s['id']}.wav"
    d = f"{r['dur']:.3f}"
    line = timings["lines"][s["id"]]
    if line.get("file"):
        ffmpeg(["-i", voice_dir / line["file"], "-af",
                f"aresample=48000,aformat=sample_fmts=s16:channel_layouts=mono,adelay={int(LEAD * 1000)},apad",
                "-t", d, "-c:a", "pcm_s16le", out])
    else:
        ffmpeg(["-f", "lavfi", "-i", "anullsrc=r=48000:cl=mono", "-t", d, "-c:a", "pcm_s16le", out])
    return out


def loudness(path):
    r = subprocess.run(["ffmpeg", "-hide_banner", "-nostdin", "-i", str(path), "-af",
                        "loudnorm=I=-16:TP=-1.5:LRA=11:print_format=json", "-f", "null", "-"],
                       capture_output=True, text=True)
    m = re.findall(r"\{[^{}]*\}", r.stderr)
    try:
        j = json.loads(m[-1])
        return {"integratedLufs": float(j["input_i"]), "truePeakDb": float(j["input_tp"])}
    except (IndexError, KeyError, ValueError):
        return None


def contact_sheet(final, total, out):
    n = int(total // 5) + 1
    rows = math.ceil(n / 6)
    font = f"fontfile={FONT}:" if Path(FONT).is_file() else ""
    vf = (f"select='not(mod(n\\,{5 * FPS}))',"
          f"drawtext={font}text='%{{pts\\:hms}}':x=16:y=16:fontsize=40:fontcolor=white:box=1:"
          f"boxcolor=0x111a4a@0.85:boxborderw=10,scale=480:270,tile=6x{rows}:padding=6:margin=6:color=0xf6f6f8")
    ffmpeg(["-i", final, "-vf", vf, "-frames:v", "1", out / "contact-sheet.png"])


def cmd_build(a):
    res = load(a.resolved)
    voice_dir, cap_dir, out = Path(a.voice_dir), Path(a.capture_dir), Path(a.out_dir)
    timings = load(voice_dir / "timings.json")
    limit = float(res["limits"]["maxSeconds"])
    out.mkdir(parents=True, exist_ok=True)
    rows, total = layout(res, timings)
    print(f"{'shot':5} {'type':9} {'start':>7} {'length':>7} {'voice':>6} {'plan':>5}")
    for r in rows:
        print(f"{r['id']:5} {r['type']:9} {r['start']:7.2f} {r['dur']:7.2f} {r['voice']:6.2f} {r['planned']:5.1f}")
    print(f"total {total:.2f} s (target {res['limits']['targetSeconds']}, limit under {limit:g})")
    n_caps = write_captions(res, rows, timings, total, out)
    timeline = {"total": total, "engine": timings["engine"], "voice": timings["voice"], "shots": rows,
                "captions": n_caps, "capture": res.get("capture")}
    (out / "timeline.json").write_text(json.dumps(timeline, indent=2) + "\n", encoding="utf-8")
    if total >= limit:
        die(f"the laid-out video is {total:.2f} s, not under {limit:g} s: shorten captions or shots")
    if a.dry_run:
        print("dry run: layout, captions.ass, captions.srt and timeline.json written; no ffmpeg")
        return
    preflight()
    work = out.parent / "work"
    work.mkdir(parents=True, exist_ok=True)
    clips, wavs = [], []
    for s, r in zip(res["shots"], rows):
        clips.append(clip_for(s, r, cap_dir, work))
        wavs.append(audio_for(s, r, voice_dir, timings, work))
        print(f"encoded {s['id']}")
    alist = work / "audio.ffconcat"
    alist.write_text("ffconcat version 1.0\n" + "".join(f"file '{w.resolve()}'\n" for w in wavs), encoding="utf-8")
    full_wav = work / "voice.wav"
    ffmpeg(["-f", "concat", "-safe", "0", "-i", alist, "-c", "copy", full_wav])
    final = out / "notice-period-demo.mp4"
    n = len(clips)
    graph = "".join(f"[{i}:v]" for i in range(n)) + f"concat=n={n}:v=1:a=0,fps={FPS},subtitles=captions.ass,format=yuv420p[v];"
    graph += f"[{n}:a]" + ("loudnorm=I=-16:TP=-1.5:LRA=11," if timings["engine"] != "none" else "") + "aresample=48000[a]"
    inputs = []
    for c in clips:
        inputs += ["-i", c.resolve()]
    inputs += ["-i", full_wav.resolve()]
    ffmpeg([*inputs, "-filter_complex", graph, "-map", "[v]", "-map", "[a]", "-t", f"{total:.3f}",
            "-c:v", "libx264", "-preset", "slow", "-crf", "20", "-profile:v", "high", "-pix_fmt", "yuv420p",
            "-r", FPS, "-c:a", "aac", "-b:a", "192k", "-ac", "2", "-movflags", "+faststart", final.name], cwd=out)
    info = probe(final)
    dur = float(info["format"]["duration"])
    v = [x for x in info["streams"] if x.get("codec_type") == "video"]
    au = [x for x in info["streams"] if x.get("codec_type") == "audio"]
    problems = []
    if dur >= limit:
        problems.append(f"length {dur:.2f} s is not under {limit:g} s")
    if not v or v[0].get("codec_name") != "h264" or (v[0].get("width"), v[0].get("height")) != (W, H) \
            or v[0].get("r_frame_rate") != f"{FPS}/1":
        problems.append(f"video stream is {v[0] if v else 'missing'}, expected h264 {W}x{H} {FPS}/1")
    if not au or au[0].get("codec_name") != "aac":
        problems.append(f"audio stream is {au[0] if au else 'missing'}, expected aac")
    loud = loudness(final) if timings["engine"] != "none" else None
    contact_sheet(final, dur, out)
    timeline.update({"file": final.name, "seconds": round(dur, 3), "bytes": final.stat().st_size, "loudness": loud})
    (out / "timeline.json").write_text(json.dumps(timeline, indent=2) + "\n", encoding="utf-8")
    summary = [f"### Demo video: {dur:.1f} s, {final.stat().st_size / 1e6:.1f} MB",
               f"voice: {timings['engine']} {timings['voice'] or ''}; loudness: "
               f"{'%.1f LUFS, true peak %.1f dB' % (loud['integratedLufs'], loud['truePeakDb']) if loud else 'n/a'}",
               "", "| shot | type | start | length | voice line |", "|---|---|---|---|---|"]
    summary += [f"| {r['id']} | {r['type']} | {r['start']:.1f} | {r['dur']:.1f} | {r['voice']:.1f} |" for r in rows]
    warns = [f"- {w}" for w in ((res.get("capture") or {}).get("warnings") or [])]
    warns += [f"- {s['id']}: {w}" for s in res["shots"] for w in (s.get("capture") or {}).get("warnings", [])]
    if warns:
        summary += ["", "Capture warnings (check the contact sheet):", *warns]
    (out / "summary.md").write_text("\n".join(summary) + "\n", encoding="utf-8")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as fh:
            fh.write("\n".join(summary) + "\n")
    print("\n".join(summary))
    if problems:
        die("; ".join(problems))
    print(f"wrote {final} ({dur:.2f} s), captions.ass, captions.srt, contact-sheet.png")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    v = sub.add_parser("voice")
    v.add_argument("resolved")
    v.add_argument("voice_dir")
    v.add_argument("--engine", choices=["edge", "espeak", "none"], required=True)
    v.add_argument("--edge-voice", default="en-US-AndrewNeural")
    b = sub.add_parser("build")
    b.add_argument("resolved")
    b.add_argument("voice_dir")
    b.add_argument("capture_dir")
    b.add_argument("out_dir")
    b.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    if a.cmd == "voice":
        cmd_voice(a)
    else:
        cmd_build(a)


if __name__ == "__main__":
    main()
