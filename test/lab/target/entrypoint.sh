#!/bin/sh
# Lab start-up: install the throwaway public key for both users, flag a pending reboot, start the lab stack in dind,
# then run sshd in the foreground. /run/rackoon-lab/ready tells the healthcheck the lab is usable.
set -eu
for u in rk rkpw; do
  install -d -m 700 -o $u -g $u /home/$u/.ssh
  install -m 600 -o $u -g $u /lab/authorized_key /home/$u/.ssh/authorized_keys
done
touch /var/run/reboot-required
export DOCKER_HOST=tcp://dind:2375
chmod -R a+rwX /srv/stacks
docker compose -p labstack -f /srv/stacks/labstack/compose.yaml up -d --quiet-pull
mkdir -p /run/rackoon-lab && touch /run/rackoon-lab/ready
exec /usr/sbin/sshd -D -e
