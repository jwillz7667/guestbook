# Guestbook container and Kubernetes lab

Justin Williams's IBM Containers final project, based on the IBM Developer Skills Network guestbook repository.

The v1 guestbook is implemented with Go's standard HTTP library. It uses a bounded, synchronized in-memory store, validates JSON requests, renders messages as text, and runs as a non-root user in a minimal multi-stage container. Messages are temporary and local to each replica; durable shared storage is outside this lab's scope.

## Local checks

```sh
cd v1/guestbook
GOTOOLCHAIN=auto go test -race ./...
docker build -t guestbook:local .
docker run --rm -p 127.0.0.1:3000:3000 guestbook:local
```

Open http://127.0.0.1:3000/ to sign the guestbook. Tests cover valid and invalid input, foreign-origin rejection, escaped output, absence of an environment disclosure endpoint, and concurrent writes with bounded retention. The cloud builder uses the official Go 1.24 image with Go 1.23 language compatibility. The course lab registry could not resolve newer official image tags/digests; the final runtime is a non-root scratch image.

## Run in the IBM Skills Network lab

```sh
git clone https://github.com/jwillz7667/guestbook.git
cd guestbook
bash run_lab.sh
```

The script requires the existing authenticated lab's Docker, Kubernetes, IBM Cloud CLI, Python, and cURL tools. It verifies the active namespace starts with `sn-labs-` and refuses to overwrite an existing guestbook deployment.

It builds and pushes v1, records the registry listing, deploys the app and a cluster-internal service, verifies an actual message submission, creates an HPA, and generates load until replicas increase. It then builds and pushes v2, reduces the requested CPU as specified by the course, captures revision 2, removes its temporary load generator and HPA, and rolls back to the exact v1 image digest. The final live HTML must show v1 again. Separate immutable image digests make rollback restore the actual earlier application.

The script saves genuine code and command output in `evidence/` and packages it as `guestbook-evidence.tar.gz` only after all live checks succeed. These outputs are for the course submission. The script does not fabricate successful output if provisioning, metrics, autoscaling, or rollback fails. A failed run needs inspection before rerunning; existing resources are deliberately retained for diagnosis.

`v1/guestbook/deployment.yml` is a template with an explicit deployment-image substitution. `run_lab.sh` writes fully resolved manifests under `evidence/` using the active lab's namespace and pushed image digests. The local application tests do not establish that the cloud lab steps have passed.
