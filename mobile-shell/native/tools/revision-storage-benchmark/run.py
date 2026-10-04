#!/usr/bin/env python3
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess


def package_decoded_bytes(path: Path) -> int:
    payload = json.loads(path.read_text())
    return sum(len(base64.b64decode(item["contentBase64"], validate=True)) for item in payload["files"])


def allocated_bytes(path: Path) -> int:
    return os.stat(path).st_blocks * 512


def store_metrics(root: Path) -> dict:
    files = [path for path in root.rglob("*") if path.is_file()]
    content_files = []
    for revision_root in root.glob("content/*/*/revisions/rev-sha256:*"):
        content_files.extend(path for path in (revision_root / "content").rglob("*") if path.is_file())
    unique = {}
    for path in content_files:
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        unique.setdefault(digest, path.stat().st_size)
    return {
        "storeLogicalBytes": sum(path.stat().st_size for path in files),
        "allocatedBytesSummedStBlocks": sum(allocated_bytes(path) for path in files),
        "contentLogicalBytes": sum(path.stat().st_size for path in content_files),
        "hashUniqueContentBytes": sum(unique.values()),
        "contentFileCount": len(content_files),
        "uniqueContentDigestCount": len(unique),
    }


def maximum_rss(stderr: str):
    for line in stderr.splitlines():
        if "maximum resident set size" in line:
            return int(line.strip().split()[0])
    return None


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("package_dir", type=Path)
    parser.add_argument("output_dir", type=Path)
    parser.add_argument("--counts", type=int, nargs="+", default=[1, 2, 10])
    args = parser.parse_args()

    tool_root = Path(__file__).resolve().parent
    subprocess.run(["swift", "build", "-c", "release"], cwd=tool_root, check=True)
    executable = tool_root / ".build" / "release" / "RevisionStorageBenchmark"
    args.output_dir.mkdir(parents=True, exist_ok=True)

    results = []
    for count in args.counts:
        package_paths = [args.package_dir / f"lunara-{index:02d}.irisapp" for index in range(1, count + 1)]
        for path in package_paths:
            if not path.is_file():
                raise FileNotFoundError(path)
        store_root = args.output_dir / f"store-{count}"
        process = subprocess.run(
            ["/usr/bin/time", "-l", str(executable), str(count), str(args.package_dir), str(store_root)],
            check=True,
            capture_output=True,
            text=True,
        )
        timing = json.loads(process.stdout)
        metrics = store_metrics(store_root)
        results.append({
            **timing,
            **metrics,
            "packageBytes": sum(path.stat().st_size for path in package_paths),
            "decodedPackageBytes": sum(package_decoded_bytes(path) for path in package_paths),
            "maxResidentSetBytes": maximum_rss(process.stderr),
        })

    report = {
        "schemaVersion": 1,
        "allocationNote": "allocatedBytesSummedStBlocks sums each file's st_blocks*512 and must not be interpreted as exclusive APFS physical bytes when clones share extents.",
        "uniqueBytesNote": "hashUniqueContentBytes is logical content bytes after SHA-256 deduplication, independent of filesystem extent sharing.",
        "results": results,
    }
    output = args.output_dir / "revision-storage-benchmark.json"
    output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(output)


if __name__ == "__main__":
    main()
