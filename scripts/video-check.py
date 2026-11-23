#!/usr/bin/env python3
"""Checks the demo video script (video/script.json) and writes what the later stages read. Standard library only.

    video-check.py [--plan OUT]                                    static checks; write the plan the recorder reads
    video-check.py --plan PLAN --capture MANIFEST --resolve OUT    after recording: fill the live values from what the
                                                                   page showed, drop skipped optional shots, write the
                                                                   resolved script for scripts/video-make.py

Static checks (exit 1 on any finding):
  - shot ids are unique, types known, planned seconds positive, the planned total under limits.maxSeconds;
  - no shown text (caption, label, end card) holds a {{...}} placeholder, a brace, a local path or a banned claim;
  - every number shown (digits, amounts, clock times, the number words zero to twelve) is one of the numbers of that
    shot's evidence. Evidence is read here, never trusted from the script: a README passage (must appear in README.md
    word for word; whitespace, ** and backticks ignored), a field of a JSON file in records/, status/ or deployments/,
    the difference of two block times in a run record, a value in docs/config.js, or a ratio of two of these;
  - hashes, explorer URLs, block numbers and contract addresses come from records/<deployment>-<run>.json and
    deployments/<deployment>.json; each one shown must also be in README.md;
  - an explorer shot's label time and "+N s" equal the record's; a replay shot's label names its run and date, and
    says "real speed, not sped up" only when the page replays that run at real speed (docs/config.js replayLong).
After recording: the Morpho line on screen is parsed (a count, no change waiting, or the dated snapshot shown when
the live read failed); the caption takes the same numbers, and anything else stops the run.
"""

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "video" / "script.json"
TYPES = {"still", "zoom", "scroll", "realtime", "card", "clip"}
EXPLORER = {"r1": "https://base-sepolia.blockscout.com/tx/", "r2": "https://lasna.reactscan.net/tx/",
            "r3": "https://base-sepolia.blockscout.com/tx/"}
ALLOWED_URLS = ("https://bongbongcrypto.github.io/notice-period/", "https://github.com/bongbongcrypto/notice-period",
                "https://base-sepolia.blockscout.com/tx/", "https://lasna.reactscan.net/tx/")
MONTHS = "Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split()
WORDS = {w: i for i, w in enumerate("zero one two three four five six seven eight nine ten eleven twelve".split())}
WORD_RE = re.compile(r"\b(" + "|".join(WORDS) + r")\b", re.I)
TIME_RE = re.compile(r"(?<![\d:])\d{1,2}:\d{2}:\d{2}(?![\d:])")
NUM_RE = re.compile(r"(?<![\w.$])\$?\d[\d,]*(?:\.\d+)?[KMB]?(?!\w)")
DATE_RE = re.compile(r"\b(\d{1,2}) (" + "|".join(MONTHS) + r") (\d{4})\b")
HASH_RE = re.compile(r"0x[0-9a-fA-F]{4,}(?:\u2026|\.\.\.)[0-9a-fA-F]{3,}|0x[0-9a-fA-F]{40}(?:[0-9a-fA-F]{24})?")
PLACEHOLDER_RE = re.compile(r"\{\{[^}]*\}\}")
LIVE_RE = re.compile(r"\{(morpho\.[a-z]+)\}")
FIELD_RE = re.compile(r"\{(pageUrl|repoUrl|event|track|deployment)\}")
BANNED = [
    (r"impossible without", "never 'impossible without'"),
    (r"\bloss(?:es)? (?:were |was |are |is )?prevented\b|\bprevent(?:s|ed|ing)? (?:a |any |the )?loss", "never 'losses prevented'"),
    (r"\b(?:AI|LLM)\b", "no text about how the idea or the code was made"),
    (r"\bhand-?written\b|\bwritten by hand\b|\bgenerated (?:by|with)\b|\bbuilt with\b", "no text about how the code was made"),
    (r"(?<![A-Za-z])[A-Za-z]:\\|(?<![A-Za-z])[A-Za-z]:/(?!/)|/home/|/Users/", "no local path"),
    (r"\bguarantee", "no guarantee"),
    (r"\blive on base sepolia\b", "v1 records no live transaction: say replay"),
]
# The three Morpho lines the page can show (docs/view.js problem / problemFailed).
MORPHO_COUNT = re.compile(r"^(\d+) rule changes? (?:is|are) waiting in (\d+) Morpho vaults? holding (\$\d+(?:\.\d)?[KMB]?) right now\.")
MORPHO_ZERO = re.compile(r"^No rule change is waiting in any listed Morpho vault right now\.")
MORPHO_FAILED = re.compile(r"^On (\d{1,2} [A-Z][a-z]{2} \d{4}): (\d+) changes waiting in (\d+) vaults holding (\$\d+(?:\.\d)?[KMB]?);")

LEAD, TAIL, READ_CPS = 0.35, 0.6, 15.0   # as in scripts/video-make.py

findings = []


def find(msg):
    findings.append(msg)
    print("FAIL " + msg)


def note(msg):
    print("note " + msg)


def norm(text):
    text = str(text).replace("**", "").replace("`", "").replace("\u00a0", " ")
    return re.sub(r"\s+", " ", text).strip()


def canon(tok):
    return tok.lstrip("$").rstrip(",").replace(",", "")


def numbers(text):
    """The numbers a text shows: clock times as they are, other numbers without $ and separators, words as digits."""
    text = str(text)
    out = set(TIME_RE.findall(text))
    rest = TIME_RE.sub(" ", text)
    out |= {canon(t) for t in NUM_RE.findall(rest)}
    out |= {str(WORDS[w.lower()]) for w in WORD_RE.findall(rest)}
    return out


def utc(ts):
    d = datetime.fromtimestamp(int(ts), tz=timezone.utc)
    return d.strftime("%H:%M:%S"), f"{d.day} {MONTHS[d.month - 1]} {d.year}"


class Repo:
    def __init__(self):
        self.readme_raw = (ROOT / "README.md").read_text(encoding="utf-8")
        self.readme = norm(self.readme_raw)
        self.config = (ROOT / "docs" / "config.js").read_text(encoding="utf-8")
        self.cache = {}

    def json(self, rel):
        path = (ROOT / rel).resolve()
        top = rel.split("/")[0]
        if ROOT not in path.parents or top not in ("records", "status", "deployments") or ".." in rel.split("/"):
            raise ValueError(f"{rel}: evidence files live in records/, status/ or deployments/")
        if rel not in self.cache:
            self.cache[rel] = json.loads(path.read_text(encoding="utf-8"))
        return self.cache[rel]

    def config_value(self, key):
        m = re.search(r"\b" + re.escape(key) + r"\s*:\s*([0-9]+(?:\.[0-9]+)?)\b", self.config)
        if not m:
            raise ValueError(f"docs/config.js has no numeric {key}")
        return m.group(1)

    def in_readme(self, h):
        """A full or shortened (0xabcd...1234) hash or address that README.md holds (case ignored)."""
        low = self.readme_raw.lower()
        h = h.lower()
        if "\u2026" in h or "..." in h:
            head, tail = re.split(r"\u2026|\.\.\.", h)
            return any(x.startswith(head) and x.endswith(tail) for x in re.findall(r"0x[0-9a-f]{40,64}", low))
        return h in low


def dig(data, dotted):
    cur = data
    for part in dotted.split("."):
        cur = cur[int(part)] if isinstance(cur, list) else cur[part]
    return cur


def evidence_text(ev, repo, fields, live):
    """The text one evidence item stands for, read from the repository (or from the screen, for live values)."""
    if "readme" in ev:
        s = norm(ev["readme"])
        if s not in repo.readme:
            raise ValueError(f"README.md does not contain: {s}")
        return s
    if "json" in ev:
        rel = FIELD_RE.sub(lambda m: str(fields[m.group(1)]), ev["json"])
        data = repo.json(rel)
        if "field" in ev:
            return str(dig(data, ev["field"]))
        if "seconds" in ev:
            a, b = ev["seconds"]
            page = data["derived"]["page"]
            return str(max(0, int(page[b]["ts"]) - int(page[a]["ts"])))
        raise ValueError(f"evidence {ev}: json needs field or seconds")
    if "config" in ev:
        return repo.config_value(ev["config"])
    if "ratio" in ev:
        a = float(evidence_text(ev["ratio"][0], repo, fields, live))
        b = float(evidence_text(ev["ratio"][1], repo, fields, live))
        return f"{a / b:.{int(ev.get('digits', 2))}f}".rstrip("0").rstrip(".")
    if "live" in ev:
        return live.get(ev["live"], "")
    raise ValueError(f"unknown evidence {ev}")


def shown_texts(shot):
    out = []
    for key in ("caption", "captionLive", "captionZero", "label", "labelFailed"):
        if shot.get(key):
            out.append((key, shot[key]))
    return out


def check_text(where, text, allow_live=False):
    if PLACEHOLDER_RE.search(text):
        find(f"{where}: placeholder left: {PLACEHOLDER_RE.search(text).group(0)[:60]}")
        return
    body = LIVE_RE.sub("", text) if allow_live else text
    if re.search(r"[{}\\]", body):
        find(f"{where}: braces and backslashes are not allowed in shown text")
    for pat, why in BANNED:
        if re.search(pat, text, re.I):
            find(f"{where}: {why}")


def covered(where, text, ev_numbers):
    missing = sorted(numbers(LIVE_RE.sub("", text)) - ev_numbers)
    if missing:
        find(f"{where}: number(s) {', '.join(missing)} not in this shot's evidence")


def check_hashes(where, text, repo):
    for h in HASH_RE.findall(text):
        if not repo.in_readme(h):
            find(f"{where}: {h} is not in README.md")


def load_script():
    script = json.loads(SCRIPT.read_text(encoding="utf-8"))
    t1 = script.get("track1") or {}
    if t1.get("enabled"):
        script["deployment"] = t1.get("deployment", script["deployment"])
        for shot in script["shots"]:
            shot.update(shot.get("ifTrack1") or {})
        script["card"].update(script["card"].get("ifTrack1") or {})
        note("Track 1 variants are on")
    return script


def run_record(repo, deployment, run):
    """The record of a run. A run number is the watch id, as on the page; the number in a record's file name is the
    order the record was written in, and the two differ once a watch was turned off or left on between two exits."""
    for path in sorted((ROOT / "records").glob(f"{deployment}-*.json")):
        rel = f"records/{path.name}"
        rec = repo.json(rel)
        page = (rec.get("derived") or {}).get("page")
        if page and str(page.get("id")) == str(run):
            return rel, rec, page
    raise ValueError(f"no record of deployment {deployment} holds run {run} with its derived page values")


def plan_shot(shot, script, repo, fields):
    where = shot["id"]
    p = {k: v for k, v in shot.items() if k not in ("ifTrack1", "evidence", "_note")}
    p["optional"] = bool(shot.get("optional"))
    if p.get("url"):
        p["url"] = FIELD_RE.sub(lambda m: str(fields[m.group(1)]), p["url"])
    run = shot.get("run")
    if run is not None:
        if PLACEHOLDER_RE.search(str(run)):
            find(f"{where}: run is a placeholder")
            return p
        rel, rec, page = run_record(repo, fields["deployment"], run)
        p["record"] = rel
        if int(page["id"]) != int(run):
            find(f"{where}: {rel} holds watch {page['id']}, not run {run}")
        t1, d1 = utc(page["r1"]["ts"])
        label = shot.get("label", "")
        if shot.get("tx"):
            tx = shot["tx"]
            if tx not in EXPLORER:
                find(f"{where}: tx must be r1, r2 or r3")
                return p
            r = page[tx]
            h = r["hash"]
            if rec.get("hash" + tx[1]) != h:
                find(f"{where}: {rel} hash{tx[1]} and derived.page.{tx}.hash differ")
            if h.lower() not in repo.readme_raw.lower():
                find(f"{where}: {h} (run {run} {tx}) is not in README.md")
            p["url"] = EXPLORER[tx] + h
            p["fresh"] = True
            p["explorer"] = "blockscout" if tx != "r2" else "reactscan"
            t, d = utc(r["ts"])
            plus = max(0, int(r["ts"]) - int(page["r1"]["ts"]))
            p["tx"] = {"key": tx, "hash": h, "block": int(r["block"]), "ts": int(r["ts"]), "utc": t, "date": d, "plus": plus}
            if tx == "r2":
                p["wait"] = {"textAny": [str(r["block"]), h[:10]]}
            else:
                p["wait"] = {"textAll": [str(r["block"])], "textAny": [h[:10], "success"]}
            p["wait"]["notText"] = ["not found", "something went wrong", "fetching transaction data",
                                    "checking your browser", "verify you are human"]
            p["soft"] = {"textAny": [t, t.lstrip("0")]}
            for lt in TIME_RE.findall(label):
                if lt != t:
                    find(f"{where}: label time {lt} is not the block time {t} of run {run} {tx}")
            for m in re.finditer(r"\+(\d+) s\b", label):
                if int(m.group(1)) != plus:
                    find(f"{where}: label says +{m.group(1)} s, the record says +{plus} s")
        if shot.get("replay"):
            p["start"] = {"hash": f"#run={int(run)}"}
            long_ = float(repo.config_value("replayLong"))
            wait = int(page["r3"]["ts"]) - int(page["r1"]["ts"])
            low = label.lower()
            if f"run {int(run)}" not in low:
                find(f"{where}: a replay label must name run {run}")
            for m in DATE_RE.finditer(label):
                if m.group(0) != d1:
                    find(f"{where}: label date {m.group(0)} is not the run's date {d1}")
            if "not sped up" in low and wait > long_:
                find(f"{where}: run {run} waited {wait} s, which the page plays faster (replayLong {long_:g}): not real speed")
            if "not sped up" not in low and "sped up" in low and wait <= long_:
                find(f"{where}: run {run} waited {wait} s, which the page plays at real speed: not sped up")
            if shot.get("type") != "realtime":
                find(f"{where}: a replay is recorded in real time (type realtime)")
        if not shot.get("tx") and not shot.get("replay"):
            find(f"{where}: run given without tx or replay")
    if p.get("url") and not p["url"].startswith(ALLOWED_URLS):
        find(f"{where}: URL {p['url']} is outside the hosted page, the repository and the two explorers")
    if shot.get("type") == "realtime":
        low = shot.get("label", "").lower()
        if "sped up" not in low:
            find(f"{where}: a realtime shot's label says 'not sped up' or 'sped up'")
        if float(shot.get("captureSeconds", 0)) <= 0:
            find(f"{where}: captureSeconds missing")
        until = shot.get("untilText", [])
        if not isinstance(until, list) or not all(isinstance(x, str) and x for x in until):
            find(f"{where}: untilText must be a list of page texts")
        if until and float(shot.get("maxCaptureSeconds", 0)) < float(shot.get("captureSeconds", 0)):
            find(f"{where}: maxCaptureSeconds must be at least captureSeconds when untilText is given")
    if shot.get("type") == "clip":
        f = ROOT / shot.get("file", "")
        if not shot.get("file") or not f.is_file():
            find(f"{where}: clip file {shot.get('file')} is missing")
    return p


def build_card(script, repo, fields):
    card = dict(script["card"])
    card.pop("ifTrack1", None)
    dep = repo.json(f"deployments/{fields['deployment']}.json")
    rows = [[k, FIELD_RE.sub(lambda m: str(fields[m.group(1)]), v)] for k, v in card["rows"]]
    contracts = []
    for label, key in card["contracts"]:
        addr = dep["contracts"].get(key)
        if not addr:
            find(f"card: deployments/{fields['deployment']}.json has no contracts.{key}")
            continue
        if not repo.in_readme(addr):
            find(f"card: {addr} ({key}) is not in README.md")
        contracts.append([label, addr])
    card["rows"], card["contracts"] = rows, contracts
    ev_numbers = set()
    for ev in card.get("evidence", []):
        try:
            ev_numbers |= numbers(evidence_text(ev, repo, fields, {}))
        except (ValueError, KeyError, IndexError) as e:
            find(f"card: evidence: {e}")
    texts = [card["title"], card["sentence"], card["note"], card["footVoice"], card["footNoVoice"]]
    texts += [f"{k} {v}" for k, v in rows] + [k for k, _ in contracts]
    for t in texts:
        check_text("card", t)
        covered("card", HASH_RE.sub(" ", t), ev_numbers)
    card.pop("evidence", None)
    return card


def static(repo):
    script = load_script()
    fields = {k: script[k] for k in ("pageUrl", "repoUrl", "event", "track", "deployment")}
    if PLACEHOLDER_RE.search(str(fields["deployment"])):
        find("deployment is a placeholder")
        return None
    limits = script["limits"]
    shots = [s for s in script["shots"] if s.get("enabled", True)]
    ids = [s.get("id") for s in script["shots"]]
    if len(ids) != len(set(ids)):
        find("shot ids are not unique")
    plan = []
    for shot in shots:
        where = shot.get("id", "?")
        if shot.get("type") not in TYPES:
            find(f"{where}: unknown type {shot.get('type')}")
            continue
        if not float(shot.get("seconds", 0)) > 0:
            find(f"{where}: seconds must be positive")
        if not shot.get("caption"):
            find(f"{where}: every shot has a caption (it is also the voice line)")
        ev_numbers = set()
        for ev in shot.get("evidence", []):
            if PLACEHOLDER_RE.search(json.dumps(ev)):
                find(f"{where}: evidence placeholder left")
                continue
            try:
                ev_numbers |= numbers(evidence_text(ev, repo, fields, {}))
            except (ValueError, KeyError, IndexError, OSError) as e:
                find(f"{where}: evidence {json.dumps(ev)[:80]}: {e}")
        for key, text in shown_texts(shot):
            check_text(f"{where} {key}", text, allow_live=(key == "captionLive"))
            covered(f"{where} {key}", text, ev_numbers)
            check_hashes(f"{where} {key}", text, repo)
        for key in ("captionLive", "captionZero"):
            if shot.get(key) and shot.get("live") != "morpho":
                find(f"{where}: {key} needs live: morpho")
        for name in LIVE_RE.findall(shot.get("captionLive", "")):
            if name not in ("morpho.changes", "morpho.vaults", "morpho.usd"):
                find(f"{where}: unknown live value {name}")
        if PLACEHOLDER_RE.search(json.dumps({k: v for k, v in shot.items() if k != "ifTrack1"})):
            find(f"{where}: a {{{{...}}}} placeholder is left in an active shot")
            continue
        plan.append(plan_shot(shot, script, repo, fields))
    card = build_card(script, repo, fields)
    total = sum(float(s["seconds"]) for s in plan)
    if total >= limits["maxSeconds"]:
        find(f"planned length {total:g} s is not under {limits['maxSeconds']} s")
    # a replay is captured until the page's own receipt check answers, at most maxCaptureSeconds, and a shot
    # also grows to fit its voice line (video-make.py: LEAD + line + TAIL); the line is estimated at READ_CPS
    worst = sum(max(float(s["seconds"]), float(s.get("maxCaptureSeconds", 0)),
                    LEAD + len(s["caption"]) / READ_CPS + TAIL) for s in plan)
    if worst >= limits["maxSeconds"]:
        find(f"planned length with every replay at its longest capture {worst:g} s is not under {limits['maxSeconds']} s")
    print(f"{'shot':5} {'type':9} {'s':>5}  label / caption")
    for s in plan:
        print(f"{s['id']:5} {s['type']:9} {float(s['seconds']):5.1f}  {s.get('label', '')[:70]}")
        print(f"{'':22}{s['caption'][:90]}")
    print(f"planned {total:g} s, {worst:g} s if every replay runs to its longest capture "
          f"(target {limits['targetSeconds']}, limit under {limits['maxSeconds']}), {len(plan)} shots")
    return {"fields": fields, "viewport": script["viewport"], "limits": limits, "voice": script["voice"],
            "card": card, "shots": plan}


def morpho_values(raw):
    """Parse the page's Morpho line. Returns (state, values) or raises ValueError."""
    text = norm(raw.get("problem", ""))
    m = MORPHO_COUNT.match(text)
    if m:
        n, v, usd = int(m.group(1)), int(m.group(2)), m.group(3)
        return "count", {"morpho.changes": f"{n} rule change" + ("" if n == 1 else "s"),
                         "morpho.vaults": f"{v} Morpho vault" + ("" if v == 1 else "s"), "morpho.usd": usd,
                         "_numbers": {str(n), str(v), canon(usd)}}
    if MORPHO_ZERO.match(text):
        return "zero", {}
    m = MORPHO_FAILED.match(text)
    if m:
        return "failed", {"_numbers": numbers(m.group(1)) | {m.group(2), m.group(3), canon(m.group(4))}}
    raise ValueError(f"the Morpho line on screen is none of the three forms the page writes: {text[:160]}")


def resolve(repo, plan, manifest):
    shots = []
    readme_snap = re.search(r"On (\d{1,2} \w{3} \d{4}) that was (\d+) changes in (\d+) vaults holding (\$[\d.]+[KMB])",
                            repo.readme)
    for p in plan["shots"]:
        m = manifest.get("shots", {}).get(p["id"])
        if p["type"] != "clip":
            if not m:
                find(f"{p['id']}: not in the capture manifest")
                continue
            if m.get("status") == "skipped":
                if not p.get("optional"):
                    find(f"{p['id']}: skipped but not optional")
                note(f"{p['id']}: optional shot skipped ({m.get('error', '')[:120]})")
                continue
            if m.get("status") != "ok":
                find(f"{p['id']}: capture {m.get('status')}: {m.get('error', '')}")
                continue
        r = dict(p)
        r["capture"] = m or {}
        if p.get("live") == "morpho":
            raw = manifest.get("live", {}).get("morpho") or {}
            try:
                state, vals = morpho_values(raw)
            except ValueError as e:
                find(f"{p['id']}: {e}")
                continue
            r["liveState"] = state
            r["liveText"] = norm(raw.get("problem", "")) + " | " + norm(raw.get("source", ""))
            if state == "count":
                r["caption"] = LIVE_RE.sub(lambda x: vals[x.group(1)], p["captionLive"])
            elif state == "zero":
                r["caption"] = p["captionZero"]
            else:
                r["caption"] = p["caption"]
                if p.get("labelFailed"):
                    r["label"] = p["labelFailed"]
                note(f"{p['id']}: Morpho's API did not answer the page; caption uses the dated snapshot the page showed")
            shown = vals.get("_numbers", set())
            said = numbers(r["caption"])
            if state != "zero" and not shown <= said:
                find(f"{p['id']}: caption numbers {sorted(said)} do not include the screen's {sorted(shown)}")
            if state == "count" and readme_snap:
                note(f"{p['id']}: live count on screen ({raw.get('problem', '')[:90]}) vs README's "
                     f"{readme_snap.group(1)} snapshot ({readme_snap.group(2)} changes, {readme_snap.group(3)} vaults, "
                     f"{readme_snap.group(4)}): caption follows the screen, which is date-stamped")
            check_text(f"{p['id']} caption", r["caption"])
        r.pop("captionLive", None)
        r.pop("captionZero", None)
        r.pop("labelFailed", None)
        shots.append(r)
    total = sum(float(s["seconds"]) for s in shots)
    if total >= plan["limits"]["maxSeconds"]:
        find(f"planned length after skips {total:g} s is not under {plan['limits']['maxSeconds']} s")
    out = dict(plan)
    out["shots"] = shots
    out["capture"] = {k: manifest.get(k) for k in ("startedAt", "finishedAt", "chrome", "voice", "noSandbox", "warnings")}
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--plan", help="plan file to write (static) or read (with --capture)")
    ap.add_argument("--capture", help="manifest.json written by scripts/video-record.mjs")
    ap.add_argument("--resolve", help="resolved script to write")
    a = ap.parse_args()
    repo = Repo()
    if a.capture:
        if not (a.plan and a.resolve):
            ap.error("--capture needs --plan and --resolve")
        plan = json.loads(Path(a.plan).read_text(encoding="utf-8"))
        manifest = json.loads(Path(a.capture).read_text(encoding="utf-8"))
        out = resolve(repo, plan, manifest)
        target = Path(a.resolve)
    else:
        out = static(repo)
        target = Path(a.plan) if a.plan else None
    if findings:
        print(f"{len(findings)} findings")
        return 1
    if target and out is not None:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(out, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        print(f"wrote {target}")
    print("video script checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
