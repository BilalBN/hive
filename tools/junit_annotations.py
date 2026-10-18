#!/usr/bin/env python3
"""Turn failed tests in a JUnit XML report into GitHub Actions error annotations,
so a failure can be read from the run summary without downloading logs."""

from __future__ import annotations

import sys
import xml.etree.ElementTree as ET


def main(path: str) -> int:
    try:
        root = ET.parse(path).getroot()
    except (OSError, ET.ParseError) as e:
        print(f"::warning::No test report to read ({e})")
        return 0
    count = 0
    for case in root.iter("testcase"):
        for problem in list(case.findall("failure")) + list(case.findall("error")):
            name = f"{case.get('classname', '')}.{case.get('name', '')}"
            text = (problem.get("message") or "") + "\n" + (problem.text or "")
            text = text.strip()[-1500:].replace("%", "%25").replace("\r", "").replace("\n", "%0A")
            print(f"::error title={name}::{text}")
            count += 1
            if count >= 10:
                return 0
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "pytest-report.xml"))
