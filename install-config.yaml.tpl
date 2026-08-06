# Reference template only.
# Run ./render-install-config.sh to generate cluster/install-config.yaml.

apiVersion: v1
credentialsMode: Mint
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
publish: Internal

platform:
  aws:
    region: ${AWS_REGION}
    hostedZone: ${HOSTED_ZONE_ID}
    vpc:
      subnets:
      - id: ${PRIVATE_SUBNET_ID}
        roles:
        - type: ClusterNode
        - type: BootstrapNode
        - type: ControlPlaneInternalLB
        - type: IngressControllerLB

controlPlane:
  name: master
  replicas: ${CONTROL_PLANE_REPLICAS}
  hyperthreading: Enabled
  platform:
    aws:
      type: ${CONTROL_PLANE_INSTANCE_TYPE}
      zones:
      - ${AVAILABILITY_ZONE}
      rootVolume:
        type: ${ROOT_VOLUME_TYPE}
        size: ${ROOT_VOLUME_SIZE_GIB}
      additionalSecurityGroupIDs:
      - ${EXTRA_SECURITY_GROUP_ID}

compute:
- name: worker
  replicas: ${WORKER_REPLICAS}
  hyperthreading: Enabled
  platform:
    aws:
      type: ${WORKER_INSTANCE_TYPE}
      zones:
      - ${AVAILABILITY_ZONE}
      rootVolume:
        type: ${ROOT_VOLUME_TYPE}
        size: ${ROOT_VOLUME_SIZE_GIB}
      additionalSecurityGroupIDs:
      - ${EXTRA_SECURITY_GROUP_ID}

networking:
  networkType: OVNKubernetes
  machineNetwork:
  - cidr: ${MACHINE_NETWORK_CIDR}
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  serviceNetwork:
  - 172.30.0.0/16

pullSecret: |
  <insert compact pull-secret JSON>
sshKey: |
  <insert SSH public key>
