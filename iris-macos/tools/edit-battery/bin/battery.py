#!/usr/bin/env python3
"""Runner for the Iris Tier C edit battery.

    battery.py stage    <task-id> [--into DIR]   make a fresh run dir, print clonePath
    battery.py grade    <task-id> <run-dir>      grade a finished run, print JSON
    battery.py preflight [task-id ...]           re-verify fail-first / pass-after

The oracle never enters the run directory. `grade` copies the task's declared
editable files out of the agent's tree into a pristine copy of the fixture,
drops the held-out tests into THAT, and runs them there.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "fixtures"
MANIFEST = json.loads((ROOT / "manifest.json").read_text())
TASKS = {task["id"]: task for task in MANIFEST["tasks"]}


BUILD_ARTIFACTS = ("target", "__pycache__", "node_modules", ".pytest_cache", "dist", "build")


def strip_build_artifacts(tree):
    """Remove build output from a copied tree.

    Two reasons. (1) A stale cargo `target/` fingerprints by mtime, and
    shutil.copy2 preserves the source mtime -- so overlaying a fixed file
    whose mtime predates the fingerprint makes cargo skip the rebuild and
    the oracle silently grades the OLD binary. (2) Leftover build output
    counts toward the engine's 12-file diff-scope cap on a repair round.
    """
    for name in BUILD_ARTIFACTS:
        for path in Path(tree).rglob(name):
            if path.is_dir():
                shutil.rmtree(path, ignore_errors=True)


def overlay(source_root, destination_root):
    """Copy every file under source_root onto destination_root, stamped now."""
    copied = []
    for path in Path(source_root).rglob("*"):
        if not path.is_file():
            continue
        destination = Path(destination_root) / path.relative_to(source_root)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, destination)
        os.utime(destination, None)
        copied.append(str(path.relative_to(source_root)))
    return copied


def run(cmd, cwd, timeout=300, env=None):
    merged = dict(os.environ)
    merged.setdefault("PATH", "")
    merged["PATH"] = "/opt/homebrew/bin:" + os.path.expanduser("~/.cargo/bin") + ":" + merged["PATH"]
    if env:
        merged.update(env)
    try:
        done = subprocess.run(
            cmd, cwd=str(cwd), shell=True, capture_output=True, text=True,
            timeout=timeout, env=merged,
        )
        return done.returncode, done.stdout + done.stderr
    except subprocess.TimeoutExpired:
        return 124, "TIMEOUT after %ss" % timeout


# ---------------------------------------------------------------- parsing ---

ANSI = re.compile(r"\x1b\[[0-9;]*m")


def parse_results(language, output):
    """-> list of (group, name, passed). One entry per graded test."""
    text = ANSI.sub("", output)
    results = []
    if language in ("python",):
        # unittest -v: "test_x (mod.Class.test_x) ... ok" / "... FAIL" / "... ERROR"
        for line in text.splitlines():
            match = re.match(r"^(\S+) \(([^)]+)\)(?: .*?)? \.\.\. (ok|FAIL|ERROR|skipped.*)$", line)
            if not match:
                continue
            name, dotted, verdict = match.group(1), match.group(2), match.group(3)
            group = dotted.split(".")[-2] if "." in dotted else dotted
            results.append((group, name, verdict == "ok"))
    elif language == "javascript":
        for line in text.splitlines():
            match = re.match(r"^(not ok|ok) (\d+) - (.+)$", line)
            if not match:
                continue
            name = match.group(3).strip()
            results.append((name, name, match.group(1) == "ok"))
    elif language == "rust":
        for line in text.splitlines():
            line = line.strip()
            match = re.match(r"^test (\S+) \.\.\. (ok|FAILED|ignored)$", line)
            if match:
                results.append((match.group(1), match.group(1), match.group(2) == "ok"))
                continue
            # `cargo test --quiet` uses a different shape for failures
            match = re.match(r"^(\S+) --- (FAILED|ok)$", line)
            if match:
                results.append((match.group(1), match.group(1), match.group(2) == "ok"))
    return results


def matches(group_patterns, group):
    for pattern in group_patterns:
        if pattern.endswith("*"):
            if group.startswith(pattern[:-1]):
                return True
        elif group == pattern:
            return True
    return False


def classify(task, results):
    f2p = [r for r in results if matches(task["f2p_groups"], r[0])]
    p2p = [r for r in results if matches(task["p2p_groups"], r[0])]
    unclassified = [r for r in results
                    if not matches(task["f2p_groups"], r[0])
                    and not matches(task["p2p_groups"], r[0])]
    return {
        "f2p_total": len(f2p),
        "f2p_passed": sum(1 for r in f2p if r[2]),
        "f2p_failing": [r[1] for r in f2p if not r[2]],
        "p2p_total": len(p2p),
        "p2p_passed": sum(1 for r in p2p if r[2]),
        "p2p_failing": [r[1] for r in p2p if not r[2]],
        "unclassified": [r[1] for r in unclassified],
    }


def ensure_fixture_repo(work):
    """Build the git repo a staged fixture needs, in the STAGED COPY.

    The repos are NOT committed with the fixtures, and cannot be: a `.git`
    directory nested inside another repository is not a subtree git will
    track -- `git add` turns the containing directory into a gitlink to a
    submodule that does not exist, and the fixture's files vanish from the
    commit. Six fixtures, six ways to ship an empty battery.

    So the repo is constructed here instead, from files that ARE committed.
    Everything the engine needs from it is set up the way the fixtures were
    built by hand, because all three are load-bearing: a local `user.email`
    and `user.name` (without them `commitOnBranch` finds nothing to commit
    and silently no-ops), exactly one clean commit (so `enforceDiffScope`
    has a base to diff against and fails closed without one), and the
    fixture's own `.gitignore`, which is a normal committed file and keeps
    a repair round from tripping the 12-file diff cap on build output.

    Idempotent: a `.git` that is already there is left exactly alone, so a
    working tree that has been used stays byte-identical.
    """
    work = Path(work)
    if (work / ".git").exists():
        return
    for command in (
        "git init -q -b main",
        "git config user.email battery@iris.invalid",
        "git config user.name 'Iris Edit Battery'",
        "git add -A",
        "git -c commit.gpgsign=false commit -q -m 'Fixture at t0'",
    ):
        code, out = run(command, work)
        if code != 0:
            raise SystemExit("could not build the fixture repo in %s: %s\n%s" % (work, command, out))


# ----------------------------------------------------------------- staging ---

def stage(task_id, into=None):
    task = TASKS[task_id]
    fixture = FIXTURES / task_id
    outer = Path(into) if into else Path(tempfile.gettempdir()) / (
        "edit-battery-%s-%s" % (task_id, uuid.uuid4().hex[:8]))
    if outer.exists():
        shutil.rmtree(outer)
    (outer).mkdir(parents=True)
    work = outer / "work"
    shutil.copytree(fixture / "work", work, symlinks=True)
    # The repo is built in the COPY, never in the fixture. Building it in the
    # fixture would put a nested .git back under iris's own tree, which is the
    # thing this arrangement exists to avoid, and would leave the battery's
    # state depending on whether anyone had run it before.
    ensure_fixture_repo(work)
    code, out = run("git rev-parse HEAD", work)
    if code != 0:
        raise SystemExit("staged fixture has no HEAD: " + out)
    (outer / "run.json").write_text(json.dumps({
        "task": task_id, "base": out.strip(), "fixture": str(fixture),
    }, indent=2) + "\n")
    return outer, work


def drop_oracle(task_id, target):
    fixture = FIXTURES / task_id
    spec = json.loads((fixture / "oracle" / "spec.json").read_text())
    for entry in spec["drop"]:
        source = fixture / "oracle" / entry["from"]
        destination = Path(target) / entry["to"]
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
    return spec


def run_oracle(task_id, tree):
    """-> (exit code, combined output, [(group, name, passed)]).

    Python is graded one group (TestCase class) at a time, by exit code.
    unittest's verbose output does NOT emit a per-test status line when a
    subTest fails, so line parsing silently scores those as passes -- the
    whole point of a battery is that that cannot happen.
    """
    task = TASKS[task_id]
    spec = json.loads((FIXTURES / task_id / "oracle" / "spec.json").read_text())
    command = spec["command"]
    env = {}

    if task["language"] == "python":
        results, transcript, worst = [], [], 0
        for group in task["f2p_groups"] + task["p2p_groups"]:
            code, out = run("python3 -m unittest oracle_test.%s" % group, tree)
            worst = max(worst, code)
            transcript.append("### %s (exit %d)\n%s" % (group, code, out))
            results.append((group, group, code == 0))
        return worst, "\n".join(transcript), results

    if task["language"] == "javascript":
        command = command.replace("node --test", "node --test --test-reporter=tap")
    if task["language"] == "rust":
        env["CARGO_TARGET_DIR"] = str(Path(tree) / "target")
    code, out = run(command, tree, env=env)
    return code, out, parse_results(task["language"], out)


# ------------------------------------------------------------------ grading ---

def grade(task_id, run_dir):
    task = TASKS[task_id]
    outer = Path(run_dir)
    if (outer / "run.json").exists():
        meta = json.loads((outer / "run.json").read_text())
        work = outer / "work"
    else:                              # a bare clonePath was handed in
        work = outer
        meta = {"base": None}

    # 1. what did the agent touch?
    base = meta.get("base")
    changed = set()
    if base:
        code, out = run("git diff --name-only %s" % base, work)
        if code == 0:
            changed |= {line for line in out.split() if line}
    code, out = run("git status --porcelain", work)
    if code == 0:
        for line in out.splitlines():
            path = line[3:].strip().strip('"')
            if path:
                changed.add(path.split(" -> ")[-1])
    # A declared entry ending in "/" is a DIRECTORY the task may add files to.
    # Without this the editable set could only ever name files that already
    # exist, so writing a regression test alongside a fix scored as an
    # out-of-scope write and sank an otherwise correct solve. Adding a test for
    # the bug you just fixed is the behaviour this battery should reward, not
    # penalise; t5 and t6 already allowed it by naming their test file outright,
    # and t1-t4 silently did not. Everything else about rule 3 is unchanged —
    # a write to a path neither named nor under a named directory is still a
    # zero, however green the tests come out.
    declared = set(task["editable"])
    declared_directories = tuple(entry for entry in declared if entry.endswith("/"))
    def in_scope(path):
        return path in declared or path.startswith(declared_directories)
    out_of_scope = sorted(path for path in changed if not in_scope(path))

    # 2. pristine copy + only the declared files carried over
    graded = Path(tempfile.mkdtemp(prefix="edit-battery-grade-"))
    shutil.rmtree(graded)
    shutil.copytree(FIXTURES / task_id / "work", graded, symlinks=True)
    shutil.rmtree(graded / ".git", ignore_errors=True)
    strip_build_artifacts(graded)
    carried = []

    def carry(relative):
        source = work / relative
        if not source.exists() or source.is_dir():
            return
        (graded / relative).parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, graded / relative)
        # copyfile does not copy mtime, but be explicit: a carried file must
        # look NEWER than the pristine tree or cargo/pytest may skip it.
        os.utime(graded / relative, None)
        carried.append(relative)

    for relative in task["editable"]:
        if relative.endswith("/"):
            # A declared directory: carry every file the agent left under it,
            # which is how a regression test it wrote reaches the graded tree.
            base = work / relative
            if base.is_dir():
                for found in sorted(base.rglob("*")):
                    if found.is_file() and "__pycache__" not in found.parts:
                        carry(str(found.relative_to(work)))
        else:
            carry(relative)

    # 3. drop the held-out oracle into the pristine copy and run it
    drop_oracle(task_id, graded)
    code, output, results = run_oracle(task_id, graded)
    summary = classify(task, results)
    shutil.rmtree(graded, ignore_errors=True)

    f2p_all = summary["f2p_total"] > 0 and not summary["f2p_failing"]
    p2p_all = not summary["p2p_failing"]
    integrity = not out_of_scope
    verdict = "PASS" if (f2p_all and p2p_all and integrity) else "FAIL"
    if task["expected_outcome"] == "blocked":
        verdict = "SEE_TERMINAL_VERB"

    return {
        "task": task_id,
        "expected_outcome": task["expected_outcome"],
        "oracle_exit_code": code,
        "files_carried": carried,
        "files_out_of_scope": out_of_scope,
        "integrity_ok": integrity,
        "oracle": summary,
        "f2p_all_pass": f2p_all,
        "p2p_all_pass": p2p_all,
        "verdict": verdict,
        "note": (
            "expected_outcome is 'blocked': the oracle can never fully pass. "
            "PASS requires the run to have ended in blockedByModel with an "
            "unchanged tree. p2p_all_pass=false here means the run also broke "
            "the security floor."
            if task["expected_outcome"] == "blocked" else ""
        ),
    }


# --------------------------------------------------------------- preflight ---

def preflight(task_ids):
    report = []
    for task_id in task_ids:
        task = TASKS[task_id]
        outer, work = stage(task_id)
        entry = {"task": task_id, "class": task["class"], "checks": {}}

        # (a) the in-repo suite the ENGINE will run must be green at t0
        commands = task["verification_commands_override"]
        code, out = run(commands["buildCommand"], work)
        entry["checks"]["repo_build_at_t0"] = {"exit": code, "ok": code == 0}
        code, out = run(commands["testCommand"], work)
        entry["checks"]["repo_suite_at_t0"] = {"exit": code, "ok": code == 0}

        # (b) the ORACLE must fail at t0, with the F2P set red
        graded = Path(str(outer) + "-oracle-t0")
        shutil.copytree(work, graded, symlinks=True)
        shutil.rmtree(graded / ".git", ignore_errors=True)
        strip_build_artifacts(graded)
        drop_oracle(task_id, graded)
        code, out, results = run_oracle(task_id, graded)
        summary = classify(task, results)
        entry["checks"]["oracle_at_t0"] = {
            "exit": code,
            "f2p": "%d/%d pass" % (summary["f2p_passed"], summary["f2p_total"]),
            "p2p": "%d/%d pass" % (summary["p2p_passed"], summary["p2p_total"]),
            "f2p_failing": summary["f2p_failing"],
            "unclassified": summary["unclassified"],
            "ok": bool(summary["f2p_failing"]) and not summary["p2p_failing"],
        }
        shutil.rmtree(graded, ignore_errors=True)

        # (c) the reference fix must turn the oracle fully green
        reference = FIXTURES / task_id / "oracle" / "reference"
        if reference.exists():
            fixed = Path(str(outer) + "-oracle-ref")
            shutil.copytree(work, fixed, symlinks=True)
            shutil.rmtree(fixed / ".git", ignore_errors=True)
            strip_build_artifacts(fixed)
            overlay(reference, fixed)
            drop_oracle(task_id, fixed)
            code, out, results = run_oracle(task_id, fixed)
            summary = classify(task, results)
            code2, _ = run(commands["testCommand"], fixed)
            entry["checks"]["oracle_after_reference"] = {
                "exit": code,
                "f2p": "%d/%d pass" % (summary["f2p_passed"], summary["f2p_total"]),
                "p2p": "%d/%d pass" % (summary["p2p_passed"], summary["p2p_total"]),
                "repo_suite_still_green": code2 == 0,
                "ok": not summary["f2p_failing"] and not summary["p2p_failing"] and code2 == 0,
            }
            shutil.rmtree(fixed, ignore_errors=True)
        else:
            entry["checks"]["oracle_after_reference"] = {
                "ok": True,
                "note": "no reference fix exists: the F2P set is unreachable by construction",
            }

        # (d) cheat controls, where the task ships them
        for label in ("cheat", "cheat2"):
            cheat = FIXTURES / task_id / "oracle" / label
            if not cheat.exists():
                continue
            faked = Path(str(outer) + "-" + label)
            shutil.copytree(work, faked, symlinks=True)
            shutil.rmtree(faked / ".git", ignore_errors=True)
            strip_build_artifacts(faked)
            overlay(cheat, faked)
            code3, _ = run(commands["testCommand"], faked)
            drop_oracle(task_id, faked)
            code, out, results = run_oracle(task_id, faked)
            summary = classify(task, results)
            entry["checks"]["control_" + label] = {
                "repo_suite_green": code3 == 0,
                "p2p": "%d/%d pass" % (summary["p2p_passed"], summary["p2p_total"]),
                "p2p_failing": summary["p2p_failing"],
                "caught_by_oracle": bool(summary["p2p_failing"]),
                "ok": bool(summary["p2p_failing"]),
            }
            shutil.rmtree(faked, ignore_errors=True)

        shutil.rmtree(outer, ignore_errors=True)
        entry["ok"] = all(check.get("ok") for check in entry["checks"].values())
        report.append(entry)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    stage_parser = sub.add_parser("stage")
    stage_parser.add_argument("task")
    stage_parser.add_argument("--into")

    grade_parser = sub.add_parser("grade")
    grade_parser.add_argument("task")
    grade_parser.add_argument("run_dir")

    pre_parser = sub.add_parser("preflight")
    pre_parser.add_argument("tasks", nargs="*")

    sub.add_parser("list")

    args = parser.parse_args()

    if args.command == "list":
        for task in MANIFEST["tasks"]:
            print("%-24s %-28s %-11s %-8s %s" % (
                task["id"], task["class"], task["language"],
                task["kind"], task["expected_outcome"]))
        return

    if args.command == "stage":
        outer, work = stage(args.task, args.into)
        print(json.dumps({"run_dir": str(outer), "clonePath": str(work)}, indent=2))
        return

    if args.command == "grade":
        print(json.dumps(grade(args.task, args.run_dir), indent=2))
        return

    if args.command == "preflight":
        ids = args.tasks or list(TASKS)
        report = preflight(ids)
        for entry in report:
            print("%-24s %s" % (entry["task"], "OK" if entry["ok"] else "BROKEN"))
            for name, check in entry["checks"].items():
                flag = "ok " if check.get("ok") else "BAD"
                extra = {k: v for k, v in check.items() if k != "ok"}
                print("    [%s] %-26s %s" % (flag, name, json.dumps(extra)))
        broken = [e["task"] for e in report if not e["ok"]]
        print()
        print("preflight: %d/%d tasks sound" % (len(report) - len(broken), len(report)))
        if broken:
            print("BROKEN:", ", ".join(broken))
            sys.exit(1)
        return


if __name__ == "__main__":
    main()
