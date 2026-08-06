FROM registry.access.redhat.com/ubi9/ubi:latest

ARG OCP_CHANNEL=stable-4.20

# UBI 9 already includes coreutils-single and curl-minimal.  Do not request
# the mutually-exclusive full coreutils/curl packages unless they are needed.
RUN dnf install -y \
      bash \
      bind-utils \
      ca-certificates \
      findutils \
      git \
      gzip \
      jq \
      less \
      procps-ng \
      tar \
      unzip \
    && dnf clean all

# AWS CLI v2 for x86_64 / Intel M8i.
RUN curl -fsSL \
      https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip \
      -o /tmp/awscliv2.zip \
    && cd /tmp \
    && unzip -q awscliv2.zip \
    && ./aws/install \
    && rm -rf /tmp/aws /tmp/awscliv2.zip

# OpenShift installer and client from the selected release channel.
RUN curl -fsSL \
      "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OCP_CHANNEL}/openshift-install-linux.tar.gz" \
      -o /tmp/openshift-install.tgz \
    && curl -fsSL \
      "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OCP_CHANNEL}/openshift-client-linux.tar.gz" \
      -o /tmp/openshift-client.tgz \
    && tar -C /usr/local/bin -xzf /tmp/openshift-install.tgz openshift-install \
    && tar -C /usr/local/bin -xzf /tmp/openshift-client.tgz oc kubectl \
    && chmod 0755 \
      /usr/local/bin/openshift-install \
      /usr/local/bin/oc \
      /usr/local/bin/kubectl \
    && rm -f /tmp/openshift-install.tgz /tmp/openshift-client.tgz

RUN mkdir -p /work /hosthome/.aws /hosthome/.ssh /hosthome/.kube /host-kubeconfig \
    && chmod 0777 /work /hosthome /hosthome/.aws /hosthome/.ssh /hosthome/.kube /host-kubeconfig

WORKDIR /work
CMD ["/bin/bash"]
