# Extracts MonitorPanel.swift's private page sections for the live-storage test package.
#
# This is the generator embedded in Tests/UI/run-monitor-panel-integration-tests.sh, kept as a
# separate file so both runners can use the same verified split. Tests/LiveIntegration owns this
# copy because the UI script cannot be changed by this work; keep them in sync if the panel's
# private declarations move. The generator reads the live file, removes the four declarations,
# and verifies that reversing its edits reproduces the source blocks.
import difflib
import hashlib
import pathlib
import sys

source_path = pathlib.Path(sys.argv[1])
panel_path = pathlib.Path(sys.argv[2])
sections_path = pathlib.Path(sys.argv[3])
render_path = pathlib.Path(sys.argv[4])
source = source_path.read_text()
lines = source.splitlines(keepends=True)

def block(start_index: int):
    depth = 0
    started = False
    collected = []
    for offset, line in enumerate(lines[start_index:]):
        collected.append(line)
        depth += line.count("{") - line.count("}")
        if "{" in line:
            started = True
        if started and depth == 0:
            return "".join(collected), start_index + offset
    raise SystemExit(f"unterminated block starting at line {start_index + 1}")

def find(declaration: str) -> int:
    matches = [i for i, line in enumerate(lines) if line.rstrip("\n") == declaration]
    if len(matches) != 1:
        raise SystemExit(f"expected exactly one {declaration!r}, found {len(matches)}")
    return matches[0]

def remove_braced(lines_to_scan, start_index: int):
    depth = 0
    started = False
    for offset, line in enumerate(lines_to_scan[start_index:]):
        depth += line.count("{") - line.count("}")
        if "{" in line:
            started = True
        if started and depth == 0:
            return start_index + offset
    raise SystemExit(f"unterminated braced block at line {start_index + 1}")

series_start = find("private enum Series {") - 1
if lines[series_start].rstrip("\n") != "@MainActor":
    raise SystemExit("Series block does not start with @MainActor")
starts = {
    "Series": series_start,
    "DiskTab": find("private struct DiskTab: View {"),
    "DiskSectionHeader": find("private struct DiskSectionHeader: View {"),
    "NetworkTab": find("private struct NetworkTab: View {"),
}

blocks = {}
ranges = {}
for name, start in starts.items():
    text, end = block(start)
    blocks[name] = text
    ranges[name] = (start, end)

edits = {
    "Series": ("@MainActor\nprivate enum Series {", "@MainActor\nenum Series {"),
    "DiskTab": ("private struct DiskTab: View {", "struct DiskTab: View {"),
    "DiskSectionHeader": ("private struct DiskSectionHeader: View {", "struct DiskSectionHeader: View {"),
    "NetworkTab": ("private struct NetworkTab: View {", "struct NetworkTab: View {"),
}

rendered = {}
for name, original in blocks.items():
    old, new = edits[name]
    if original.count(old) != 1:
        raise SystemExit(f"{name}: expected exactly one visibility edit")
    changed = original.replace(old, new)
    if changed.replace(new, old) != original:
        raise SystemExit(f"{name}: reversing the visibility edit did not reproduce the source")
    rendered[name] = changed

# Render-only DiskTab: same body minus the two lifecycle modifiers.
disk_tab = rendered["DiskTab"]
disk_render = disk_tab.replace("struct DiskTab: View {", "struct DiskTabRender: View {", 1)
if disk_render == disk_tab:
    raise SystemExit("DiskTabRender: name edit did not apply")
disk_lines = disk_render.splitlines(keepends=True)
task_start = next((i for i, line in enumerate(disk_lines) if line == "        .task {\n"), None)
if task_start is None:
    raise SystemExit("DiskTabRender: .task block not found")
task_end = remove_braced(disk_lines, task_start)
on_receive_start = task_end + 1
if not disk_lines[on_receive_start].startswith(
        "        .onReceive(NotificationCenter.default.publisher(for: .monitoringHistoryCleared))"):
    raise SystemExit("DiskTabRender: .onReceive block does not follow .task")
on_receive_end = remove_braced(disk_lines, on_receive_start)
removed = "".join(disk_lines[task_start:on_receive_end + 1])
for marker in (".task {", "selection.connect(reader:", "monitoringHistoryCleared", "selection.historyDidClear()"):
    if marker not in removed:
        raise SystemExit(f"DiskTabRender: removed block is missing {marker!r}")
without_lifecycle = "".join(disk_lines[:task_start] + disk_lines[on_receive_end + 1:])
reconstructed = "".join(disk_lines[:task_start]) + removed + "".join(disk_lines[on_receive_end + 1:])
if reconstructed != disk_render:
    raise SystemExit("DiskTabRender: removing the lifecycle block was not reversible")
if ".task {" in without_lifecycle or ".onReceive(" in without_lifecycle:
    raise SystemExit("DiskTabRender: a lifecycle modifier remains")
disk_render = without_lifecycle

# Render-only NetworkTab: same body with the live section replaced by a boundary stub.
network_tab = rendered["NetworkTab"]
network_render = network_tab.replace("struct NetworkTab: View {",
                                     "struct NetworkTabRender: View {", 1)
live_line = "            NetworkDetailsSection()\n"
boundary_line = "            NetworkDetailsSectionBoundary()\n"
if network_render.count(live_line) != 1:
    raise SystemExit("NetworkTabRender: expected exactly one NetworkDetailsSection() line")
network_render = network_render.replace(live_line, boundary_line, 1)
if network_render.replace(boundary_line, live_line, 1).replace(
        "struct NetworkTabRender: View {", "struct NetworkTab: View {", 1) != network_tab:
    raise SystemExit("NetworkTabRender: reversing the render edits did not reproduce the source")

def unified(original: str, changed: str, label: str) -> str:
    diff = difflib.unified_diff(original.splitlines(keepends=True),
                                changed.splitlines(keepends=True),
                                fromfile=label + " (source)",
                                tofile=label + " (generated)",
                                n=2)
    return "".join(diff)

removed = set()
for start, end in ranges.values():
    removed.update(range(start, end + 1))
panel = "".join(line for index, line in enumerate(lines) if index not in removed)
panel_path.write_text(panel)

common_header = (
    "// Generated by Tests/UI/run-monitor-panel-integration-tests.sh from\n"
    "// App/Monitor/MonitorPanel.swift. The declarations below are copied byte-for-byte from the\n"
    "// production file; only `private` was removed so the test target can construct and render\n"
    "// them. The generator verifies that reversing those edits reproduces the source blocks.\n"
    "// The same declarations are removed from the package's MonitorPanel.swift copy so the module\n"
    "// has one copy of each type; the rest of that file is compiled unchanged.\n"
    "// The imports mirror MonitorPanel.swift; the declarations are not edited.\n\n"
    "import AppKit\n"
    "import Charts\n"
    "import Metrics\n"
    "import Storage\n"
    "import SwiftUI\n\n"
)
sections = common_header + "\n".join(rendered[name] for name in ("Series", "DiskTab", "DiskSectionHeader", "NetworkTab"))
sections_path.write_text(sections)

boundary = '''
/// Test-only boundary for the live network section. `NetworkDetailsSection` owns a default
/// sampler that reads real interfaces; `NetworkTabRender` replaces that one call with this view
/// so the tab's production chrome can be rendered without a system read.
struct NetworkDetailsSectionBoundary: View {
    var body: some View {
        Text("Live network section boundary (not rendered)")
            .font(.mh(size: 10.5))
            .foregroundStyle(Palette.textFaint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Palette.inset, in: SurfaceShape(cornerRadius: 8, style: .continuous))
    }
}
'''
render_header = (
    "// Generated by Tests/UI/run-monitor-panel-integration-tests.sh from\n"
    "// App/Monitor/MonitorPanel.swift. These render-only variants exist because `ImageRenderer`\n"
    "// can run SwiftUI lifecycle modifiers in the same process: `DiskTabRender` drops only the\n"
    "// `.task`/`.onReceive` block (the test drives the model directly), and `NetworkTabRender`\n"
    "// replaces only the live `NetworkDetailsSection()` call with a boundary view. Every other\n"
    "// line is the production text. The full `DiskTab`/`NetworkTab` remain compiled in\n"
    "// `MonitorPanelSections.swift` and are used by `MonitorPanel`.\n\n"
    "import AppKit\n"
    "import Charts\n"
    "import Metrics\n"
    "import Storage\n"
    "import SwiftUI\n\n"
)
render_file = render_header + disk_render + "\n" + network_render + "\n" + boundary
render_path.write_text(render_file)

print(f"MonitorPanel.swift sha256: {hashlib.sha256(source.encode()).hexdigest()}")
print(f"MonitorPanelSections.swift sha256: {hashlib.sha256(sections.encode()).hexdigest()}")
print(f"MonitorPanelRenderSections.swift sha256: {hashlib.sha256(render_file.encode()).hexdigest()}")
print(f"panel remainder sha256: {hashlib.sha256(panel.encode()).hexdigest()}")
for name, original in blocks.items():
    start, end = ranges[name]
    print(f"extracted {name}: lines {start + 1}-{end + 1}, {len(original.splitlines())} lines, byte-identical except visibility")
print("--- DiskTabRender differences ---")
print(unified(disk_tab, disk_render, "DiskTab"))
print("--- NetworkTabRender differences ---")
print(unified(network_tab, network_render, "NetworkTab"))
