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

## Optional SOCKS5 proxy for bastion SSH

If direct outbound SSH is blocked, set the proxy only in the external private configuration file, not in the repository:

```bash
SSH_PROXY_HOST="proxy-us.intel.com"
SSH_PROXY_PORT="1080"
```

When `SSH_PROXY_HOST` is non-empty, `copy-to-bastion.sh` and `ssh-bastion.sh` automatically use:

```text
ProxyCommand=nc -X 5 -x <proxy-host>:<proxy-port> %h %p
```

Leave `SSH_PROXY_HOST` empty for normal direct SSH. The workstation must have a netcat implementation that supports `-X` and `-x`.
