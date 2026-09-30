"""SSH-only receiver; reads JSON lines on stdin and stores activity rows."""

import argparse
import json
import os
import sys
from pathlib import Path

from store import cursor_state, ingest


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('cursor', 'ingest'))
    parser.add_argument('source')
    args = parser.parse_args()
    path = Path(os.environ.get('TELEMETRY_DB', str(Path.home() / '.local/share/llama-telemetry/activity.sqlite')))
    if args.action == 'cursor':
        print(json.dumps(cursor_state(path, args.source)))
    else:
        print(ingest(path, args.source, sys.stdin))


if __name__ == '__main__':
    main()
