# Container workflow

The container image packages the AWS CLI, `oc`, and `openshift-install`. Deployment configuration and credentials stay outside Git.

Expected host-side inputs are normally:

```text
~/.config/openshift-aws/config.env
~/.config/openshift-aws/pull-secret.txt
~/.aws/config
~/.aws/credentials              # optional when using an IAM role
~/.ssh/<public-key>
```

On the bastion:

```bash
./setup-docker.sh
./container.sh build
./container.sh versions
./container.sh preflight
./container.sh deploy
```

Useful commands:

```bash
./container.sh kubeconfig
./container.sh status
./container.sh oc get nodes -o wide
./container.sh logs
./container.sh shell
```

The container mounts the external configuration read-only, mounts `~/.aws` read-only when present, and keeps generated installer state under the repository's ignored `cluster/` directory.
