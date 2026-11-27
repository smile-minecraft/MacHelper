#!/usr/bin/env python3
"""Lists the failed tests of a `swift test` log or an `xcodebuild test` result bundle.

Used by scripts/ci/run-tests.sh. Every output line is one failed test, tab separated:

    <rerun filter>\t<display name>\t<repo-relative file or empty>\t<line or empty>\t<message>

The filter is what the runner needs to run that test alone: a `swift test --filter` regular
expression for a package test, or the `-only-testing:` identifier for an app test. The command
exits 0 when it listed every failure, 3 when the input failed in a way it cannot attribute to a
test (a compile error, a crashed test host), so the caller must not rerun anything.

Subcommands:
    swift-log <log>          parse the output of `swift test`
    xcresult <bundle>        read a result bundle with `xcrun xcresulttool`
    summary-errors <log>     print the error lines of a log that could not be parsed
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from typing import Iterable

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
UNATTRIBUTED = 3

# Swift Testing: `✘ Test name() recorded an issue at File.swift:12:5: Expectation failed: …`.
# The leading symbol differs between terminals (✘ or an SF Symbols code point), so it is skipped.
SWIFT_TESTING_ISSUE = re.compile(
    r"Test (?P<name>.+?) recorded an issue(?: with .*?)? at "
    r"(?P<file>[^\s:]+\.swift):(?P<line>\d+):(?:\d+): (?P<message>.*)$"
)
# Swift Testing's summary line of a failed run: `✘ Test run with 12 tests in 3 suites failed …`.
SWIFT_TESTING_RUN_FAILED = re.compile(r"Test run with \d+ tests? .*failed")
# XCTest: `/path/File.swift:12: error: -[Target.Class testName] : message`.
XCTEST_FAILURE = re.compile(
    r"(?:(?P<file>[^\s:]+):(?P<line>\d+): )?error: -\[(?P<module>\w+)\.(?P<cls>\w+) "
    r"(?P<test>\w+)\] : (?P<message>.*)$"
)
# A crash or a compile error ends the run without naming every test it affected.
UNATTRIBUTABLE = re.compile(
    r"^\S+\.swift:\d+:\d+: error:|Exited with (?:unexpected )?signal|Fatal error:|"
    r"error: fatalError|Test runner hung|encountered an error"
)
FUNC = re.compile(r"\bfunc\s+(?P<name>[A-Za-z_]\w*)\s*[(<]")
IDENTIFIER_CALL = re.compile(r"^(?P<name>[A-Za-z_]\w*)\(")

_tracked: list[str] | None = None


def tracked_swift_files() -> list[str]:
    global _tracked
    if _tracked is None:
        try:
            out = subprocess.run(["git", "-C", ROOT, "ls-files", "*.swift"],
                                 capture_output=True, text=True, check=True).stdout
            _tracked = out.splitlines()
        except (OSError, subprocess.CalledProcessError):
            _tracked = []
    return _tracked


def resolve(path: str) -> str:
    """Turns a file name from a log into a repository-relative path when it is unambiguous."""
    if not path:
        return ""
    if os.path.isabs(path):
        rel = os.path.relpath(path, ROOT)
        return rel if not rel.startswith("..") else path
    if os.path.exists(os.path.join(ROOT, path)):
        return path
    base = os.path.basename(path)
    matches = [f for f in tracked_swift_files() if os.path.basename(f) == base]
    # Prefer test sources: a failure is recorded in a test file.
    tests = [f for f in matches if f.startswith("Tests/")]
    for candidates in (tests, matches):
        if len(candidates) >= 1:
            return candidates[0]
    return path


def enclosing_function(path: str, line: int) -> str | None:
    """The name of the `func` that contains `line`, read from the source file."""
    full = os.path.join(ROOT, path)
    try:
        with open(full, encoding="utf-8") as handle:
            lines = handle.readlines()
    except OSError:
        return None
    for index in range(min(line, len(lines)) - 1, -1, -1):
        match = FUNC.search(lines[index])
        if match:
            return match.group("name")
    return None


def clean(text: str) -> str:
    return text.replace("\t", " ").replace("\r", " ").replace("\n", " ").strip()


def emit(rows: Iterable[tuple[str, str, str, str, str]]) -> None:
    for row in rows:
        print("\t".join(clean(str(part)) for part in row))


def parse_swift_log(log_path: str) -> int:
    with open(log_path, encoding="utf-8", errors="replace") as handle:
        lines = handle.read().splitlines()

    rows: dict[str, tuple[str, str, str, str, str]] = {}
    unattributed = False
    for raw in lines:
        line = raw.strip()
        if UNATTRIBUTABLE.search(line):
            unattributed = True
        match = SWIFT_TESTING_ISSUE.search(line)
        if match:
            name = match.group("name")
            file = resolve(match.group("file"))
            number = match.group("line")
            call = IDENTIFIER_CALL.match(name)
            function = call.group("name") if call else enclosing_function(file, int(number))
            if not function:
                unattributed = True
                continue
            # Swift Testing IDs look like `Module.Suite/function(label:)`.
            key = f"/{function}\\("
            rows.setdefault(key, (key, name, file, number, match.group("message")))
            continue
        match = XCTEST_FAILURE.search(line)
        if match:
            key = f"{match.group('module')}.{match.group('cls')}/{match.group('test')}$"
            name = f"{match.group('cls')}.{match.group('test')}"
            rows.setdefault(key, (key, name, resolve(match.group("file") or ""),
                                  match.group("line") or "", match.group("message")))

    emit(rows.values())
    if unattributed or not rows:
        return UNATTRIBUTED
    return 0


def xcresulttool(*args: str) -> object:
    out = subprocess.run(["xcrun", "xcresulttool", *args], capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip() or f"xcresulttool exited {out.returncode}")
    return json.loads(out.stdout)


def first_failure(node: dict) -> tuple[str, str, str]:
    """File, line and message of the first failure under a test case node. Arguments of a
    parameterized test nest their failures one level deeper."""
    for child in node.get("children", []):
        if child.get("nodeType") == "Failure Message":
            text = child.get("name") or ""
            location = child.get("sourceLocation") or {}
            if location.get("filePath"):
                return (resolve(location["filePath"]), str(location.get("lineNumber") or ""), text)
            # Older result bundles put the location in the text: `File.swift:12: message`.
            located = re.match(r"(?P<file>[^\s:]+):(?P<line>\d+): (?P<message>.*)", text, re.S)
            if located:
                return (resolve(located.group("file")), located.group("line"),
                        located.group("message"))
            return ("", "", text)
        found = first_failure(child)
        if found != ("", "", ""):
            return found
    return ("", "", "")


def failures_from_test_results(bundle: str) -> tuple[list[tuple[str, str, str, str, str]], bool]:
    """Xcode 16+: `xcresulttool get test-results tests`."""
    data = xcresulttool("get", "test-results", "tests", "--path", bundle)
    rows: list[tuple[str, str, str, str, str]] = []
    unattributed = False

    def walk(node: dict, target: str | None) -> None:
        nonlocal unattributed
        kind = node.get("nodeType")
        if kind == "Unit test bundle":
            target = node.get("name")
        if kind == "Test Case" and node.get("result") == "Failed":
            identifier = node.get("nodeIdentifier") or ""
            name = identifier or node.get("name") or ""
            if not target or "/" not in identifier:
                unattributed = True
                return
            file, number, message = first_failure(node)
            rows.append((f"{target}/{identifier}", name, file, number, message))
            return
        for child in node.get("children", []):
            walk(child, target)

    for node in data.get("testNodes", []):  # type: ignore[union-attr]
        walk(node, None)
    return rows, unattributed


def failures_from_legacy(bundle: str) -> tuple[list[tuple[str, str, str, str, str]], bool]:
    """Older Xcode: `xcresulttool get --legacy --format json`."""
    data = xcresulttool("get", "--legacy", "--format", "json", "--path", bundle)
    summaries = (data.get("issues", {})  # type: ignore[union-attr]
                 .get("testFailureSummaries", {}).get("_values", []))
    rows: list[tuple[str, str, str, str, str]] = []
    unattributed = False
    for summary in summaries:
        name = summary.get("testCaseName", {}).get("_value", "")
        target = summary.get("producingTarget", {}).get("_value", "")
        message = summary.get("message", {}).get("_value", "")
        url = (summary.get("documentLocationInCreatingWorkspace", {})
               .get("url", {}).get("_value", ""))
        file, number = "", ""
        located = re.match(r"file://(?P<path>[^#]+)#.*?StartingLineNumber=(?P<line>\d+)", url)
        if located:
            file = resolve(located.group("path"))
            number = str(int(located.group("line")) + 1)
        # `Suite.test()` → `Suite/test()`
        if not target or "." not in name:
            unattributed = True
            continue
        suite, _, test = name.rpartition(".")
        rows.append((f"{target}/{suite}/{test}", name, file, number, message))
    return rows, unattributed


def parse_xcresult(bundle: str) -> int:
    if not os.path.isdir(bundle):
        return UNATTRIBUTED
    try:
        rows, unattributed = failures_from_test_results(bundle)
    except (RuntimeError, json.JSONDecodeError):
        try:
            rows, unattributed = failures_from_legacy(bundle)
        except (RuntimeError, json.JSONDecodeError) as error:
            print(f"xcresulttool could not read {bundle}: {error}", file=sys.stderr)
            return UNATTRIBUTED
    seen: set[str] = set()
    unique = [row for row in rows if not (row[0] in seen or seen.add(row[0]))]
    emit(unique)
    if unattributed or not unique:
        return UNATTRIBUTED
    return 0


def summary_errors(log_path: str) -> int:
    try:
        with open(log_path, encoding="utf-8", errors="replace") as handle:
            lines = handle.read().splitlines()
    except OSError:
        return 0
    pattern = re.compile(r"error:|fatal error|encountered an error|\*\* (TEST|BUILD) .*FAILED|"
                         + SWIFT_TESTING_RUN_FAILED.pattern)
    shown: list[str] = []
    for line in lines:
        text = line.strip()
        if pattern.search(text) and text not in shown:
            shown.append(text)
        if len(shown) >= 30:
            break
    print("\n".join(shown))
    return 0


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 64
    command, target = argv[1], argv[2]
    if command == "swift-log":
        return parse_swift_log(target)
    if command == "xcresult":
        return parse_xcresult(target)
    if command == "summary-errors":
        return summary_errors(target)
    print(__doc__, file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
