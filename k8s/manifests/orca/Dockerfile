FROM debian:bookworm-slim

ARG ORCA_VERSION=1.4.253
ARG ORCA_DEB_SHA256=982fc25b1805dc8be66096b9a1ebcaf0b55eec3966b5c6ee606919797263d572
ARG GH_VERSION=2.103.3
ARG GH_TARBALL_SHA256=4c806978ffce1cec70853302a56d70ac6da4f19bae7adca4e1a8ab00633dd91d
ARG AWSCLI_VERSION=2.39.6
ARG AWSCLI_ZIP_SHA256=7a121264f2637a3b90767aaf5bdd43ee88b8c925a931d0479fa2ce22b1a2fa76
ARG SPIFFE_HELPER_VERSION=0.12.3
ARG SPIFFE_HELPER_TARBALL_SHA256=b275a572d36ec02f5da995c11c736b3300ab5210af21f3deff1b5fc727cecd69

LABEL org.opencontainers.image.source="https://github.com/dancavallaro/homelab"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash ca-certificates curl git jq openssh-client procps tini unzip \
    && curl -fsSL -o /tmp/orca.deb \
        "https://github.com/stablyai/orca/releases/download/v${ORCA_VERSION}/orca-ide_${ORCA_VERSION}_amd64.deb" \
    && echo "${ORCA_DEB_SHA256}  /tmp/orca.deb" | sha256sum -c - \
    && apt-get install -y --no-install-recommends /tmp/orca.deb \
    && curl -fsSL -o /tmp/gh.tar.gz \
        "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" \
    && echo "${GH_TARBALL_SHA256}  /tmp/gh.tar.gz" | sha256sum -c - \
    && mkdir -p /opt/gh && tar -xzf /tmp/gh.tar.gz -C /opt/gh --strip-components=1 \
    && curl -fsSL -o /tmp/awscli.zip \
        "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${AWSCLI_VERSION}.zip" \
    && echo "${AWSCLI_ZIP_SHA256}  /tmp/awscli.zip" | sha256sum -c - \
    && unzip -q /tmp/awscli.zip -d /tmp && /tmp/aws/install \
    && curl -fsSL -o /tmp/spiffe-helper.tar.gz \
        "https://github.com/spiffe/spiffe-helper/releases/download/v${SPIFFE_HELPER_VERSION}/spiffe-helper_v${SPIFFE_HELPER_VERSION}_Linux-x86_64.tar.gz" \
    && echo "${SPIFFE_HELPER_TARBALL_SHA256}  /tmp/spiffe-helper.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/spiffe-helper.tar.gz -C /usr/local/bin spiffe-helper \
    && rm -rf /tmp/* /var/lib/apt/lists/* \
    && useradd --uid 1000 --create-home --shell /bin/bash orca \
    && rm -f /etc/machine-id && ln -s /home/orca/.machine-id /etc/machine-id \
    && git config --system credential.https://github.com.helper github-app \
    && git config --system user.name 'orca-homelab[bot]' \
    && git config --system user.email 'orca-homelab[bot]@users.noreply.github.com'

COPY spiffe-helper.hcl /etc/orca/spiffe-helper.hcl
COPY entrypoint.sh /usr/local/bin/orca-entrypoint
COPY github-app-token.sh /usr/local/bin/github-app-token
COPY git-credential-github-app.sh /usr/local/bin/git-credential-github-app
COPY gh-wrapper.sh /usr/local/bin/gh

USER orca
ENV HOME=/home/orca \
    PATH=/home/orca/.local/bin:/usr/local/bin:/usr/bin:/bin \
    ORCA_SERVE_RUNTIME=orcad
WORKDIR /home/orca
EXPOSE 6768
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/orca-entrypoint"]
