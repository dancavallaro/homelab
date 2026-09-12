terraform {
  required_providers {
    spirl = {
      source = "registry.opentofu.org/spirl/spirl"
      version = ">= 0.14.0"
    }
  }
}

# To set up:
# > defakto iam wif-issuer set talos-prod https://oidc.cavnet.io
# > defakto iam service-account create dan-sa --role-name Admin
# > defakto iam service-account wif-config set dan-sa talos-prod --claim sub=system:serviceaccount:default:dan
#
# To run:
# > SPIRL_OIDC_TOKEN=$(kubectl create token dan -n default --audience testing123 --duration 10m) terraform plan
provider "spirl" {
  service_account_id = "sa-ggweev8hpa"
  # Set the SPIRL_OIDC_TOKEN env var to avoid setting oidc_token explicitly
}

resource "spirl_trust_domain" "prod" {
  domain_name = "prod.cavallaro.local"
}

resource "spirl_trust_domain_config" "prod" {
  trust_domain_id = spirl_trust_domain.prod.id
  sections = {
    TokenExchangePolicy = <<-YAML
      section: TokenExchangePolicy
      schema: v1
      spec:
        allowlist:
          - issuer: https://pocket-id.o.cavnet.cloud
            audiences:
              - 816acb21-3d87-470c-8d90-8c17ee9da65c
    YAML
  }
}

resource "spirl_trust_domain_deployment" "prod" {
  trust_domain_id = spirl_trust_domain.prod.id
  name            = "talos-prod"
  # This is only here to satisfy the Terraform provider - this TDD will use keyless authentication.
  keys            = {
    "unused-placeholder" = {
        public_key = <<EOF
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEANoPrivateKeyExistsForThisPlaceholderKeyless=
-----END PUBLIC KEY-----
EOF
        active     = false
    }
  }
}

resource "spirl_trust_domain_deployment_config" "prod" {
  trust_domain_deployment_id = spirl_trust_domain_deployment.prod.id
  sections = {
    TrustDomainServerAttestation = <<-YAML
      section: TrustDomainServerAttestation
      schema: v1
      spec:
        requiredAttestors:
          - type: k8s_token
            config:
              issuerURL: https://oidc.cavnet.io
              serviceAccountNamespace: ${spirl_trust_domain_deployment.prod.id}
              serviceAccountName: ${spirl_trust_domain_deployment.prod.id}-spirl-server
    YAML

    KeyManager = <<-YAML
      section: KeyManager
      schema: v1
      spec:
        extensions:
          awsKMS:
            region: us-east-1
    YAML
  }
}

resource "spirl_cluster" "talos-prod" {
  trust_domain_id = spirl_trust_domain.prod.id
  name            = "talos-prod"
  platform        = "k8s"
}

resource "spirl_cluster_config" "talos-prod" {
  cluster_id = spirl_cluster.talos-prod.id
  sections = {
    AgentAttestation = <<-YAML
      section: AgentAttestation
      schema: v1
      spec:
        policies:
          - name: k8s_policy
            requiredAttestors:
              - type: k8s_token
                config:
                  issuerURL: https://oidc.cavnet.io
    YAML
  }
}

resource "spirl_cluster" "linux-servers" {
  trust_domain_id = spirl_trust_domain.prod.id
  name            = "linux-servers"
  platform        = "linux"
}

resource "spirl_cluster_config" "linux-servers" {
  cluster_id = spirl_cluster.linux-servers.id
  sections = {
    AgentAttestation = <<-YAML
      section: AgentAttestation
      schema: v1
      spec:
        policies:
          - name: linux_policy
            requiredAttestors:
              - type: http_dns
                config:
                  allowedHostnames:
                    - "*.lan"
                  allowedPorts:
                    - 8080
    YAML

    WorkloadAttestation = <<-YAML
      section: WorkloadAttestation
      schema: v1
      spec:
        kubernetes:
          enabled: false
        docker:
          enabled: true
        linux:
          enabled: true
    YAML

    SVIDIssuancePolicy = <<-YAML
      section: SVIDIssuancePolicy
      schema: v1
      spec:
        policy:
          pathTemplate: "/{{node_group.name}}/{{http_dns.hostname}}/{{docker.container.label[com.docker.compose.service]}}"
    YAML
  }
}
