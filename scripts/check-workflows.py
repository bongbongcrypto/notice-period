#!/usr/bin/env python3
"""Text checks of .github/workflows (standard library; run by the ci.yml lint step). Exit 1 on any finding.

Every workflow:
  - has a top-level `permissions:` block and no `pull_request_target` trigger;
  - every job has `timeout-minutes`;
  - no step uses an outside action (`uses:`), since the repository checks out and installs with plain shell. The one
    exception is ALLOWED_ACTIONS: an action named there, pinned by exactly that full commit hash, in a job that
    reads no secret (video.yml uploads its artifact with it; no other way to upload exists from a run step);
  - no `set -x`, and no `--private-key` followed by a literal `$` expansion echoed with `echo`;
  - a job that reads secrets.TESTNET_KEY runs in `environment: testnet`, and only such jobs name that environment;
  - every `${{ inputs.X }}` refers to a declared input;
  - a `schedule:` trigger only with `github.event.repository.private == false` in the `if:` of every job.
loop.yml: every LOOP_* variable that scripts/loop-system.sh or scripts/chain.sh reads is set in the env of the
  "System loop" step, or is a tuning value with a default in the script (TUNING below).
health.yml: every variable scripts/health.sh requires (need_env) is set in the job or the step env.
If PyYAML happens to be installed, every workflow is also parsed with it; without it that part is skipped and said so.
"""

import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WF = ROOT / ".github" / "workflows"
# Outside actions allowed, each pinned by the commit its release tag points to (read from the action's own repository
# with the GitHub API on 2026-11-22: tag v7.0.2 -> this commit, identical to main; runs on node24). Only its
# action.yml was read; the code that runs, dist/upload/index.js, is GitHub's own bundle and was not reviewed.
ALLOWED_ACTIONS = {"actions/upload-artifact": "cf430e030ddbb5b0abf93d22962f4752f3646cd9"}
TUNING = {"LOOP_AMOUNT", "LOOP_TIMEOUT", "LOOP_IGNORE_WAIT", "LOOP_REVOKE_AFTER", "LOOP_BURST_WAIT", "LOOP_SCAN",
          "LOOP_WATCH_KINDS", "LOOP_NO_KEY_A"}

findings = []


def find(msg):
    findings.append(msg)
    print("FAIL " + msg)


def indent(line):
    return len(line) - len(line.lstrip(" "))


def block(lines, start):
    """Lines after `start` that are indented deeper than lines[start] (blank and comment lines kept)."""
    base = indent(lines[start])
    out = []
    for line in lines[start + 1:]:
        if line.strip() and not line.lstrip().startswith("#") and indent(line) <= base:
            break
        out.append(line)
    return out


def keys_at(lines, level):
    return [(i, line.strip().split(":")[0]) for i, line in enumerate(lines)
            if line.strip() and not line.lstrip().startswith("#") and indent(line) == level
            and re.match(r"^[A-Za-z0-9_.-]+:", line.strip())]


def jobs_of(lines):
    top = dict((k, i) for i, k in keys_at(lines, 0))
    if "jobs" not in top:
        return {}
    body = block(lines, top["jobs"])
    return {name: block(body, i) for i, name in keys_at(body, 2)}


def env_keys(lines):
    """Keys of every `env:` mapping inside these lines."""
    keys = set()
    for i, line in enumerate(lines):
        if line.strip() == "env:":
            for _, k in keys_at(block(lines, i), indent(line) + 2):
                keys.add(k)
    return keys


def step(lines, name):
    for i, line in enumerate(lines):
        if re.match(r"^\s*- name: " + re.escape(name) + r"\s*$", line):
            out = [line.replace("- ", "  ", 1)]
            for nxt in lines[i + 1:]:
                if nxt.strip() and indent(nxt) <= indent(line):
                    break
                out.append(nxt)
            return out
    return None


def declared_inputs(lines):
    for i, line in enumerate(lines):
        if line.strip() == "inputs:":
            return {k for _, k in keys_at(block(lines, i), indent(line) + 2)}
    return set()


def check_workflow(path):
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    name = path.name
    top = dict((k, i) for i, k in keys_at(lines, 0))
    if "permissions" not in top:
        find(f"{name}: no top-level permissions block")
    if "pull_request_target" in text:
        find(f"{name}: pull_request_target trigger")
    for ref in re.findall(r"^\s*(?:-\s+)?uses:\s*([^\s#]+)", text, re.M):
        action, _, pin = ref.partition("@")
        if ALLOWED_ACTIONS.get(action) != pin:
            find(f"{name}: a step uses an outside action ({ref}); only {sorted(ALLOWED_ACTIONS)} at their pinned commits")
    if re.search(r"\bset -[a-wyz]*x", text):
        find(f"{name}: set -x would print secrets")
    if re.search(r"echo[^\n]*--private-key", text):
        find(f"{name}: a private key option is echoed")
    inputs = declared_inputs(lines)
    for used in sorted(set(re.findall(r"\binputs\.([A-Za-z0-9_-]+)", text))):
        if used not in inputs:
            find(f"{name}: inputs.{used} is used but not declared")
    on_block = block(lines, top["on"]) if "on" in top else []
    scheduled = any(k == "schedule" for _, k in keys_at(on_block, 2))
    jobs = jobs_of(lines)
    if not jobs:
        find(f"{name}: no jobs found")
    for job, body in jobs.items():
        keys = dict((k, i) for i, k in keys_at(body, 4))
        if "timeout-minutes" not in keys:
            find(f"{name}: job {job} has no timeout-minutes")
        jtext = "\n".join(body)
        env_line = next((body[i] for k, i in keys.items() if k == "environment"), "")
        uses_key = "secrets.TESTNET_KEY" in jtext
        # any form of reading a secret: secrets.X, secrets['X'], toJSON(secrets)
        if re.search(r"^\s*(?:-\s+)?uses:", jtext, re.M) and re.search(r"\bsecrets\b", jtext):
            find(f"{name}: job {job} runs an outside action and reads a secret")
        if uses_key and "testnet" not in env_line:
            find(f"{name}: job {job} reads the testnet key outside the testnet environment")
        if "testnet" in env_line and not uses_key:
            find(f"{name}: job {job} names the testnet environment but signs nothing")
        if scheduled:
            cond = body[keys["if"]] if "if" in keys else ""
            if "github.event.repository.private == false" not in cond:
                find(f"{name}: scheduled, but job {job} lacks the guard github.event.repository.private == false")
    return lines


def script_vars(*scripts):
    out = set()
    for s in scripts:
        out |= set(re.findall(r"\bLOOP_[A-Z0-9_]+", (ROOT / s).read_text(encoding="utf-8")))
    return out


def check_loop(lines):
    st = step(lines, "System loop")
    if st is None:
        find("loop.yml: no step named 'System loop'")
        return
    mapped = env_keys(st)
    for v in sorted(script_vars("scripts/loop-system.sh", "scripts/chain.sh")):
        if v not in mapped and v not in TUNING:
            find(f"loop.yml: {v} is read by the loop script but not set in the System loop step")
    for v in sorted(k for k in mapped if k.startswith("LOOP_")):
        if v not in script_vars("scripts/loop-system.sh", "scripts/chain.sh"):
            find(f"loop.yml: {v} is set but the loop script never reads it")
    for need in ("NP_TOKEN", "NP_FACTORY", "NP_EXIT", "NP_REACTIVE", "DEPLOY_KEY"):
        if need not in mapped:
            find(f"loop.yml: {need} is not set in the System loop step")


def check_health(lines):
    sh = (ROOT / "scripts" / "health.sh").read_text(encoding="utf-8")
    need = set()
    for m in re.finditer(r"^need_env (.+)$", sh, re.M):
        need |= set(m.group(1).split())
    have = env_keys(lines)
    for v in sorted(need | {"DEPLOY_KEY", "LOOP_FACTORY_KIND"}):
        if v not in have:
            find(f"health.yml: {v} (needed by scripts/health.sh) is not set")
    if re.search(r"LOOP_FUND_B:\s*\"?1", "\n".join(lines)):
        find("health.yml: key B must never be funded from key A here")


def main():
    files = sorted(WF.glob("*.yml"))
    if not files:
        find("no workflows found")
    parsed = {}
    for f in files:
        parsed[f.name] = check_workflow(f)
    if "loop.yml" in parsed:
        check_loop(parsed["loop.yml"])
    else:
        find("loop.yml missing")
    if "health.yml" in parsed:
        check_health(parsed["health.yml"])
    try:
        import yaml  # optional
    except ImportError:
        print("note PyYAML not installed: YAML parse skipped, text checks only")
    else:
        for f in files:
            try:
                doc = yaml.safe_load(f.read_text(encoding="utf-8"))
                if not isinstance(doc, dict) or "jobs" not in doc:
                    find(f"{f.name}: YAML has no jobs mapping")
            except yaml.YAMLError as e:
                find(f"{f.name}: YAML does not parse: {str(e).splitlines()[0]}")
    if findings:
        print(f"{len(findings)} findings")
        return 1
    print(f"workflow checks passed ({len(files)} files)")
    return 0


if __name__ == "__main__":
    os.chdir(ROOT)
    sys.exit(main())
