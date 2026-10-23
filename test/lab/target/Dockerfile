# The lab's "server": Ubuntu with sshd and the standard tools Rackoon's scripts use. Docker is the dind sidecar
# (DOCKER_HOST is set for every ssh session). Everything here is test-only.
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      openssh-server sudo iproute2 procps coreutils findutils tar apt-utils ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=docker:27-cli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker:27-cli /usr/local/libexec/docker/cli-plugins/ /usr/local/libexec/docker/cli-plugins/

# Users: rk (key login, passwordless sudo), rkpw (key login, sudo wants its password).
RUN useradd -m -s /bin/bash rk && useradd -m -s /bin/bash rkpw \
    && echo 'rkpw:lab-sudo-password' | chpasswd \
    && echo 'rk ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/rk \
    && echo 'rkpw ALL=(ALL) ALL' > /etc/sudoers.d/rkpw \
    && echo 'Defaults:rkpw passwd_tries=1' >> /etc/sudoers.d/rkpw \
    && chmod 440 /etc/sudoers.d/*

# A local apt archive with one ordinary and one security update, so `apt list --upgradable` has a known answer offline.
COPY apt/ /lab/apt/
RUN sh /lab/apt/build.sh

COPY stubs/ /usr/local/sbin/
COPY stacks/ /srv/stacks/
COPY entrypoint.sh /lab/entrypoint.sh
RUN chmod +x /usr/local/sbin/* /lab/entrypoint.sh && mkdir -p /run/sshd \
    && printf 'PasswordAuthentication no\nPermitRootLogin no\nSetEnv DOCKER_HOST=tcp://dind:2375\n' > /etc/ssh/sshd_config.d/lab.conf
ENTRYPOINT ["/lab/entrypoint.sh"]
