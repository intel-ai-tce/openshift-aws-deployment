# OpenShift on AWS Deployment

Container-first scripts for deploying a private OpenShift cluster into an existing AWS VPC, administered through a public bastion host.

## Architecture

```text
Workstation
  |
  | SSH
  v
Public bastion
  |
  | Docker toolbox: aws + oc + openshift-install
  v
Private OpenShift cluster
  |- control-plane nodes
  `- worker nodes
```

The repository intentionally contains **no AWS-account-specific values or secrets**. Environment configuration and credentials are installed outside the source checkout.

## 1. Install private configuration on the workstation

Recommended local layout:

```text
~/.config/openshift-aws/config.env
~/.config/openshift-aws/pull-secret.txt
~/.aws/config
~/.aws/credentials              # only for static-credential flow
~/.ssh/<bastion-private-key>
~/.ssh/<bastion-public-key>
```

You can create the configuration manually from the template:

```bash
mkdir -p ~/.config/openshift-aws
cp config.env.example ~/.config/openshift-aws/config.env
chmod 700 ~/.config/openshift-aws
chmod 600 ~/.config/openshift-aws/config.env
vim ~/.config/openshift-aws/config.env
```

Or use a separately distributed private configuration bundle containing your environment-specific files.

The default configuration path is:

```text
~/.config/openshift-aws/config.env
```

Override it when needed:

```bash
CONFIG_FILE=/secure/path/lab.env ./preflight.sh
```

AWS authentication can come from `~/.aws`, environment variables, or preferably an appropriate IAM role. Never add AWS secret keys to this repository.

## 2. Workstation: create and enter bastion

```bash
./create-bastion.sh
./copy-to-bastion.sh
./ssh-bastion.sh
```

`copy-to-bastion.sh` transfers:

- generic source code to the configured bastion directory
- external `config.env` and pull secret to `~/.config/openshift-aws/`
- the configured SSH **public** key to `~/.ssh/`
- `~/.aws/config` and `~/.aws/credentials` when they exist (static-credential flow)

The SSH **private** key is never copied to the bastion. If the bastion uses an IAM instance profile, `~/.aws/credentials` is unnecessary.

## 3. Bastion: container workflow

```bash
cd ~/openshift-aws-deployment
./setup-docker.sh
./container.sh build
./container.sh versions
./container.sh preflight
./container.sh deploy
```

Check cluster state:

```bash
./container.sh status
./container.sh oc get nodes -o wide
./container.sh oc get co
```

The wrapper uses kubeconfig in this order:

1. `<repo>/cluster/auth/kubeconfig`
2. host `$KUBECONFIG`
3. host `~/.kube/config`

Show the selected kubeconfig with:

```bash
./container.sh kubeconfig
```

## 4. Destroy

On the bastion:

```bash
./container.sh destroy-cluster
```

On the workstation:

```bash
./terminate-bastion.sh
```

## Repository safety

Before publishing or opening a PR:

```bash
./check-upstream-safe.sh
```

The check rejects common local state, credential patterns, and concrete AWS account/resource identifiers.

Never commit:

- `config.env`
- Red Hat pull secrets
- AWS access/secret keys
- SSH private keys
- kubeconfigs or kubeadmin passwords
- generated `cluster/` installer state
- `.bastion.env`

## Main files

| File | Purpose |
|---|---|
| `config.env.example` | Empty deployment configuration template |
| `create-bastion.sh` | Create/reuse the public bastion |
| `copy-to-bastion.sh` | Copy source plus required external runtime files to bastion |
| `setup-docker.sh` | Prepare Docker on the bastion |
| `container.sh` | Container workflow entry point |
| `preflight.sh` | Validate AWS/VPC/DNS/routing prerequisites |
| `render-install-config.sh` | Generate OpenShift install config |
| `install-cluster.sh` | Create/resume cluster |
| `status.sh` | Show installer and cluster status |
| `destroy-cluster.sh` | Destroy cluster through installer metadata |
| `terminate-bastion.sh` | Terminate bastion |
| `check-upstream-safe.sh` | Guard against publishing local/account data |
