#!/usr/bin/env bash
# Resume only the final verification of a run that already reached rollback.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"
exec > >(tee -a evidence/final-verification.log) 2>&1
NAMESPACE="$(kubectl config view --minify -o 'jsonpath={..namespace}')"
case "$NAMESPACE" in sn-labs-*) ;; *) echo 'Expected the course lab namespace'; exit 1;; esac
for file in deployment-v1.yml live-v1.html live-v2.html hpa2.txt rev.txt rs.txt; do test -s "evidence/$file"; done
EXPECTED="$(python3 - <<'PY'
from pathlib import Path
import re
print(re.search(r'image: (\S+)',Path('evidence/deployment-v1.yml').read_text())[1])
PY
)"
ACTUAL="$(kubectl get deployment guestbook -o jsonpath='{.spec.template.spec.containers[0].image}')"
test "$ACTUAL" = "$EXPECTED"
kubectl rollout status deployment/guestbook --timeout=180s
export EXPECTED
FORWARD_PID=''
cleanup() { if [[ -n "$FORWARD_PID" ]]; then kill "$FORWARD_PID" 2>/dev/null || true; wait "$FORWARD_PID" 2>/dev/null || true; fi; }
trap cleanup EXIT
PASSED=0
for retry in $(seq 1 6); do
 POD="$(kubectl get pods -l app=guestbook -o json | python3 -c 'import json,sys,os; ps=json.load(sys.stdin)["items"]; names=[p["metadata"]["name"] for p in ps if not p["metadata"].get("deletionTimestamp") and p["status"].get("phase")=="Running" and p["spec"]["containers"][0]["image"]==os.environ["EXPECTED"] and any(c.get("ready") for c in p["status"].get("containerStatuses",[]))]; print(names[0] if names else "")')"
 if [[ -z "$POD" ]]; then sleep 3; continue; fi
 echo "Verifying restored pod: $POD"
 kubectl port-forward "pod/$POD" 3001:3000 > evidence/port-forward-final.log 2>&1 &
 FORWARD_PID=$!
 for attempt in $(seq 1 15); do
  if curl -fsS http://127.0.0.1:3001/ > evidence/live-restored.html && grep -q 'Guestbook - v1' evidence/live-restored.html; then PASSED=1; break; fi
  if ! kill -0 "$FORWARD_PID" 2>/dev/null; then break; fi
  sleep 2
 done
 cleanup
 FORWARD_PID=''
 if [[ "$PASSED" = 1 ]]; then break; fi
done
[[ "$PASSED" = 1 ]]
kubectl get deployment guestbook -o wide
kubectl get rs -l app=guestbook | tee evidence/rs.txt
printf 'Verified restored image: %s\n' "$ACTUAL"
python3 - <<'PY'
from pathlib import Path
import hashlib,json
root=Path('evidence')
manifest={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in root.iterdir() if p.is_file() and p.name not in ('run.log','manifest.json','final-verification.log')}
(root/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
PY
tar -czf guestbook-evidence.tar.gz evidence
printf '\nALL LIVE CONTAINER CHECKS PASSED\nEvidence: %s/guestbook-evidence.tar.gz\n' "$ROOT"
