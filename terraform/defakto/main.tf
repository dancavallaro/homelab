terraform {
  required_providers {
    spirl = {
      source = "registry.opentofu.org/spirl/spirl"
      version = ">= 0.14.0"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
      version = ">= 2.0.0"
    }
  }
}

provider "kubernetes" {
  config_path = "~/.kube/config"
}

# The webhook's serving cert is issued by cluster-ca-issuer; reading its CA here
# rather than pasting it means cert-manager renewals can't silently drift.
data "kubernetes_secret_v1" "cluster_ca" {
  metadata {
    name      = "self-signed-issuer-ca"
    namespace = "cert-manager"
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

    # yamlencode rather than a heredoc because caCerts is interpolated, and
    # heredoc indent-stripping does not apply to interpolated content.
    ServerlessAttestation = yamlencode({
      section = "ServerlessAttestation"
      schema  = "v1"
      spec = {
        policies = [{
          name = "esp32_policy"
          svidPolicy = {
            pathTemplate = "/iot/{{custom.device_id}}"
          }
          requiredAttestors = [{
            type = "extension"
            config = {
              webhookURL = "https://esp32-attestor.defakto-webhook.svc.cluster.local:8443/attest"
              timeout    = "5s"
              # nonsensitive: a CA certificate is public, and marking it sensitive
              # would hide this whole section from terraform plan output.
              caCerts = nonsensitive(data.kubernetes_secret_v1.cluster_ca.data["tls.crt"])
            }
          }]
        }]
      }
    })
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

    SVIDIssuancePolicy = <<-YAML
      section: SVIDIssuancePolicy
      schema: v1
      spec:
        policy:
          pathTemplate: "/{{cluster.name}}/ns/{{kubernetes.pod.namespace}}/sa/{{kubernetes.pod.service_account}}"
          x509:
            dnsNames:
              - "{{kubernetes.pod.service_account}}.o.cavnet.cloud"
          jwt:
            ttl: 30m
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
                    - 3470
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

resource "spirl_cluster" "networking-secure" {
  trust_domain_id = spirl_trust_domain.prod.id
  name            = "networking-secure"
  platform        = "linux"
}

resource "spirl_cluster_config" "networking-secure" {
  cluster_id = spirl_cluster.networking-secure.id
  sections = {
    AgentAttestation = <<-YAML
      section: AgentAttestation
      schema: v1
      spec:
        policies:
          - name: bf3_policy
            requiredAttestors:
              - type: tpm_ek
                config:
                  allowedHashes:
                    # The BF3 has no manufacturer EK cert in NV, so we have to pin the EK public key directly.
                    - "98fb69a90a9325d28ec352c24842beeb677c27afddbe84c017af70d125fe0ce2"
    YAML

    WorkloadAttestation = <<-YAML
      section: WorkloadAttestation
      schema: v1
      spec:
        kubernetes:
          enabled: false
        docker:
          enabled: false
        linux:
          enabled: true
        systemd:
          enabled: true
    YAML

    SVIDIssuancePolicy = <<-YAML
      section: SVIDIssuancePolicy
      schema: v1
      spec:
        policy:
          pathTemplate: "/{{node_group.name}}/{{tpm_ek.public_hash}}/{{systemd.id}}"
    YAML
  }
}
