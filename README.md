# OpenShift on AWS Deployment

Container-first scripts for deploying a private OpenShift cluster into an existing AWS VPC, administered through a public bastion host.

## Architecture

```mermaid
%%{init: {
  "flowchart": {
    "htmlLabels": true,
    "nodeSpacing": 60,
    "rankSpacing": 80,
    "curve": "basis"
  }
}}%%

flowchart TB

    Intel["Intel Workstation"]

    subgraph AWS["AWS — us-west-2"]
        subgraph VPC["Intel VPC"]

            subgraph PUB["Public Subnet"]
                PubInfo["subnet-062ac395426b3ba1a<br/>10.0.144.0/20"]

                Bastion["OpenShift Bastion<br/>m8i.large<br/>Public IPv4"]
            end

            subgraph PRIV["Private Subnet"]
                PrivInfo["subnet-0526424c31d749532<br/>10.0.32.0/19"]

                API["Private API<br/>api.cpu-test.ocp-test.internal:6443"]

                Masters["3 Control Plane Nodes<br/>m8i.4xlarge"]

                Workers["2 Worker Nodes<br/>m8i.24xlarge"]

                Bootstrap["Bootstrap Node<br/>Temporary"]
            end
        end
    end

    Intel -->|"SSH TCP/22"| Bastion

    Bastion -->|"openshift-install<br/>oc commands"| API

    API --> Masters
    API --> Workers

    Bootstrap -.->|"Install only"| Masters

    PubInfo --- Bastion
    PrivInfo --- API
````

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

### Create a new bastion and a new cluster

To keep the existing environment and create a second one, copy the private configuration and change only the bastion and cluster names:

```bash
cp ~/.config/openshift-aws/config.env ~/.config/openshift-aws/config-new.env
vim ~/.config/openshift-aws/config-new.env
```

For example:

```bash
BASTION_NAME="ocp-public-bastion-2"
CLUSTER_NAME="cpu-test-2"
```

Keep the existing AWS account, VPC, subnets, Route53 zone, security groups, credentials, and instance types unless a different environment is desired. Then use the new configuration:

```bash
export CONFIG_FILE="$HOME/.config/openshift-aws/config-new.env"

./create-bastion.sh
./copy-to-bastion.sh
./ssh-bastion.sh
```

On the new bastion, continue with the normal container workflow below.

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
