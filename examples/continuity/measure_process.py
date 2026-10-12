"""Measure one benchmark process, including compilation and child processes."""
import datetime
import json
import resource
import subprocess
import sys
import time

if len(sys.argv) < 3:
    raise SystemExit("usage: measure_process.py NEW_RESULT.json COMMAND...")
with open(sys.argv[1], "x") as output:
    started = datetime.datetime.now(datetime.timezone.utc).isoformat()
    start = time.monotonic()
    result = subprocess.run(sys.argv[2:])
    json.dump({
        "started": started,
        "command": sys.argv[2:],
        "seconds": time.monotonic() - start,
        "returncode": result.returncode,
        "maxrss_kib": resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss,
    }, output, indent=2)
raise SystemExit(result.returncode)
