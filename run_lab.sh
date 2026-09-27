#!/usr/bin/env bash
# Run only in the enrolled IBM Skills Network OpenShift lab.
set -euo pipefail
cd "$(dirname "$0")"
TASK_ROOT="$PWD"
TASK_EVIDENCE="$TASK_ROOT/evidence"
mkdir -p "$TASK_EVIDENCE"
exec > >(tee -a "$TASK_EVIDENCE/run.log") 2>&1
TASK_NAMESPACE="$(kubectl config view --minify -o 'jsonpath={..namespace}')"
case "$TASK_NAMESPACE" in sn-labs-*) ;; *) echo 'Expected the active Skills Network namespace; refusing deployment.'; exit 1;; esac
TASK_IMAGE="us.icr.io/$TASK_NAMESPACE/guestbook"
if kubectl get deployment guestbook >/dev/null 2>&1; then
  echo 'A guestbook deployment already exists. Inspect it before rerunning this lab.'; exit 1
fi
printf 'Namespace: %s\n' "$TASK_NAMESPACE"
cp v1/guestbook/Dockerfile "$TASK_EVIDENCE/Dockerfile"
cp v1/guestbook/public/index.html "$TASK_EVIDENCE/app.txt"
docker build -t "$TASK_IMAGE:v1" v1/guestbook
docker push "$TASK_IMAGE:v1" | tee "$TASK_EVIDENCE/push-v1.txt"
ibmcloud cr images | tee "$TASK_EVIDENCE/crimages.txt"
# Resolve the immutable digest so rollback restores v1 even after later pushes.
TASK_V1_DIGEST="$(docker inspect --format='{{index .RepoDigests 0}}' "$TASK_IMAGE:v1")"
test -n "$TASK_V1_DIGEST"
cat > "$TASK_EVIDENCE/deployment-v1.yml" <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: guestbook
  labels: {app: guestbook}
spec:
  replicas: 1
  selector:
    matchLabels: {app: guestbook}
  strategy:
    type: RollingUpdate
    rollingUpdate: {maxSurge: 1, maxUnavailable: 0}
  template:
    metadata:
      labels: {app: guestbook}
    spec:
      containers:
        - name: guestbook
          image: $TASK_V1_DIGEST
          imagePullPolicy: Always
          ports: [{containerPort: 3000, name: http}]
          resources:
            limits: {cpu: 50m, memory: 64Mi}
            requests: {cpu: 20m, memory: 16Mi}
          readinessProbe:
            httpGet: {path: /healthz, port: 3000}
            initialDelaySeconds: 2
          livenessProbe:
            httpGet: {path: /healthz, port: 3000}
            initialDelaySeconds: 10
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: [ALL]}
---
apiVersion: v1
kind: Service
metadata:
  name: guestbook
spec:
  selector: {app: guestbook}
  ports: [{port: 3000, targetPort: 3000}]
YAML
kubectl apply -f "$TASK_EVIDENCE/deployment-v1.yml"
kubectl rollout status deployment/guestbook --timeout=300s
kubectl port-forward deployment/guestbook 3000:3000 > "$TASK_EVIDENCE/port-forward.log" 2>&1 &
TASK_FORWARD_PID=$!
trap 'kill "$TASK_FORWARD_PID" 2>/dev/null || true' EXIT
for task_attempt in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:3000/ > "$TASK_EVIDENCE/live-v1.html"; then break; fi
  sleep 2
done
rg -q 'Guestbook - v1' "$TASK_EVIDENCE/live-v1.html" || grep -q 'Guestbook - v1' "$TASK_EVIDENCE/live-v1.html"
curl -fsS -H 'Content-Type: application/json' -d '{"message":"Hello from Justin Williams"}' http://127.0.0.1:3000/api/entries | tee "$TASK_EVIDENCE/entry-response.json"
kubectl autoscale deployment guestbook --cpu-percent=5 --min=1 --max=10
kubectl get hpa guestbook | tee "$TASK_EVIDENCE/hpa.txt"
cat > "$TASK_EVIDENCE/load-generator.yml" <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: guestbook-load
  labels: {app: guestbook-load}
spec:
  restartPolicy: Never
  containers:
    - name: load
      image: busybox:1.37.0
      command: [sh, -c, 'while true; do wget -q -O /dev/null http://guestbook:3000/; done']
      resources:
        limits: {cpu: 100m, memory: 32Mi}
        requests: {cpu: 10m, memory: 8Mi}
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: {drop: [ALL]}
YAML
kubectl apply -f "$TASK_EVIDENCE/load-generator.yml"
TASK_SCALED=0
for task_attempt in $(seq 1 60); do
  kubectl get hpa guestbook | tee -a "$TASK_EVIDENCE/hpa-watch.txt"
  TASK_REPLICAS="$(kubectl get hpa guestbook -o jsonpath='{.status.currentReplicas}')"
  if [ "${TASK_REPLICAS:-0}" -gt 1 ]; then TASK_SCALED=1; break; fi
  sleep 10
done
kubectl describe hpa guestbook | tee "$TASK_EVIDENCE/hpa2.txt"
if [ "$TASK_SCALED" -ne 1 ]; then echo 'Autoscaling did not increase replicas; inspect HPA metrics before submission.'; exit 1; fi
# These temporary resources were created by this lab run.
kubectl delete pod guestbook-load --wait=true
python3 - <<'PY'
from pathlib import Path
p=Path('v1/guestbook/public/index.html')
p.write_text(p.read_text().replace('Guestbook - v1','Guestbook – v2'))
PY
cp v1/guestbook/public/index.html "$TASK_EVIDENCE/up-app.txt"
docker build -t "$TASK_IMAGE:v2" v1/guestbook
docker push "$TASK_IMAGE:v2" | tee "$TASK_EVIDENCE/upguestbook.txt"
TASK_V2_DIGEST="$(docker inspect --format='{{index .RepoDigests 0}}' "$TASK_IMAGE:v2")"
export TASK_V1_DIGEST TASK_V2_DIGEST TASK_EVIDENCE
python3 - <<'PY'
import os
from pathlib import Path
root=Path(os.environ['TASK_EVIDENCE'])
s=(root/'deployment-v1.yml').read_text().replace(os.environ['TASK_V1_DIGEST'],os.environ['TASK_V2_DIGEST']).replace('cpu: 50m','cpu: 5m').replace('cpu: 20m','cpu: 2m')
(root/'deployment-v2.yml').write_text(s)
PY
kubectl apply -f "$TASK_EVIDENCE/deployment-v2.yml" | tee "$TASK_EVIDENCE/deployment.txt"
kubectl rollout status deployment/guestbook --timeout=300s
kill "$TASK_FORWARD_PID" 2>/dev/null || true
kubectl port-forward deployment/guestbook 3000:3000 > "$TASK_EVIDENCE/port-forward-v2.log" 2>&1 &
TASK_FORWARD_PID=$!
for task_attempt in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:3000/ > "$TASK_EVIDENCE/live-v2.html" && grep -q 'Guestbook – v2' "$TASK_EVIDENCE/live-v2.html"; then break; fi
  sleep 2
done
grep -q 'Guestbook – v2' "$TASK_EVIDENCE/live-v2.html"
kubectl rollout history deployment/guestbook | tee "$TASK_EVIDENCE/history.txt"
kubectl rollout history deployment/guestbook --revision=2 | tee "$TASK_EVIDENCE/rev.txt"
kubectl delete hpa guestbook
kubectl scale deployment guestbook --replicas=1
kubectl rollout status deployment/guestbook --timeout=300s
kubectl get rs -l app=guestbook | tee "$TASK_EVIDENCE/rs-before.txt"
kubectl rollout undo deployment/guestbook --to-revision=1
kubectl rollout status deployment/guestbook --timeout=300s
kubectl get rs -l app=guestbook | tee "$TASK_EVIDENCE/rs.txt"
TASK_RESTORED="$(kubectl get deployment guestbook -o jsonpath='{.spec.template.spec.containers[0].image}')"
[ "$TASK_RESTORED" = "$TASK_V1_DIGEST" ]
kill "$TASK_FORWARD_PID" 2>/dev/null || true
kubectl port-forward deployment/guestbook 3000:3000 > "$TASK_EVIDENCE/port-forward-restored.log" 2>&1 &
TASK_FORWARD_PID=$!
for task_attempt in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:3000/ > "$TASK_EVIDENCE/live-restored.html" && grep -q 'Guestbook - v1' "$TASK_EVIDENCE/live-restored.html"; then break; fi
  sleep 2
done
grep -q 'Guestbook - v1' "$TASK_EVIDENCE/live-restored.html"
python3 - <<'PY'
from pathlib import Path
import hashlib,json
root=Path('evidence')
manifest={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in root.iterdir() if p.is_file() and p.name not in ('run.log','manifest.json')}
(root/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
PY
tar -czf "$TASK_ROOT/guestbook-evidence.tar.gz" -C "$TASK_ROOT" evidence
printf '\nALL LIVE CONTAINER CHECKS PASSED\nEvidence: %s/guestbook-evidence.tar.gz\n' "$TASK_ROOT"
