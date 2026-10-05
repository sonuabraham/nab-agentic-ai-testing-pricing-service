"""Builds this repo's ECG content graph using the `ecg` package from the
test-graph repo (https://github.com/sonuabraham/test-graph) - the same
`process_workspace` call its web server's /process endpoint makes.

Run by scripts/build_ecg_graph.sh, which clones test-graph and puts it on
PYTHONPATH. Usage:

    python3 scripts/build_ecg_graph.py <source_dir> <output_dir>

Writes nodes.jsonl / edges.jsonl (plus a report.json) into <output_dir>.
No docs and no Ollama extractor/embedder in CI, so only the code-graph build
(+ contract discovery and cross-service linking) runs; the ingest / resolve /
link / index steps report "skipped".
"""

from __future__ import annotations

import json
import shutil
import sys
import tempfile
from pathlib import Path

from ecg.web.pipeline import PipelineConfig, process_workspace
from ecg.web.workspace import Workspace


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    source = Path(sys.argv[1]).resolve()
    output = Path(sys.argv[2]).resolve()

    with tempfile.TemporaryDirectory() as tmp:
        ws = Workspace(Path(tmp) / "workspaces", source.name)
        ws.dir.mkdir(parents=True)
        ws.docs_dir.mkdir()
        # Symlink rather than copy: the builder resolves the path, so git
        # history (contributor signals) is read from the real checkout.
        ws.code_dir.symlink_to(source, target_is_directory=True)

        config = PipelineConfig(
            extractor=None, embedder=None, link_code_and_docs=False, build_index=False
        )
        report = process_workspace(ws, config, on_progress=lambda m: print(f"    {m}"))

        if not (ws.out_dir / "nodes.jsonl").exists():
            print("ECG build produced no graph", file=sys.stderr)
            print(json.dumps(report.to_json(), indent=2), file=sys.stderr)
            return 1

        if output.exists():
            shutil.rmtree(output)
        shutil.copytree(ws.out_dir, output, ignore=shutil.ignore_patterns(".cache"))

    (output / "report.json").write_text(json.dumps(report.to_json(), indent=2))
    print(json.dumps(report.to_json(), indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
