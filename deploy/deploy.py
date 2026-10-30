#!/usr/bin/env python3
"""Deploy all three immutable ViewVee images to existing Compose projects."""
import base64
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
SERVICES = {'web': 'viewvee-web', 'signaling': 'viewvee-signal', 'turn': 'viewvee-turn'}


def targets(raw):
    result = []
    for line in raw.splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        parts = line.strip().split('|')
        if len(parts) != 7:
            raise ValueError('Each target must have seven pipe-separated fields')
        service, host, port, folder, health, app, proxy = parts
        if service not in SERVICES:
            raise ValueError(f'Unknown service: {service}')
        if not re.fullmatch(r'[A-Za-z0-9._-]+@[A-Za-z0-9][A-Za-z0-9.-]*', host):
            raise ValueError('Invalid SSH destination')
        if not port.isascii() or not port.isdigit() or not 1 <= int(port) <= 65535:
            raise ValueError('Invalid SSH port')
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]*', folder):
            raise ValueError('Invalid Compose folder')
        if not (health == 'running' and service == 'turn') and not re.fullmatch(r'[0-9]{1,5}/[A-Za-z0-9._/-]*', health):
            raise ValueError('Invalid health check')
        if service == 'turn' and health != 'running':
            raise ValueError('TURN must use the running health check')
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', app):
            raise ValueError('Invalid Compose service')
        if proxy != '-' and not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', proxy):
            raise ValueError('Invalid proxy container')
        result.append((service, host, port, folder, health, app, proxy))
    if {x[0] for x in result} != set(SERVICES):
        raise ValueError('Configure at least one target for each of web, signaling, and turn')
    if len({(x[1], x[3], x[5]) for x in result}) != len(result):
        raise ValueError('Duplicate Compose service target')
    return result


def remote(target, image, mode):
    service, host, port, folder, health, app, proxy = target
    user = os.environ['GHCR_USER']
    token = os.environ['GHCR_TOKEN']
    if not re.fullmatch(r'[A-Za-z0-9_-]+(?:\[bot\])?', user) or not token or '\n' in token or '\r' in token:
        raise ValueError('Invalid registry credentials')
    encoded = base64.b64encode((ROOT / 'remote-deploy.sh').read_bytes()).decode()
    args = shlex.join([folder, image, mode, health, user, app, proxy])
    bootstrap = ('set -eu; IFS= read -r REGISTRY_TOKEN; export REGISTRY_TOKEN; '
                 'printf %s ' + shlex.quote(encoded) + ' | base64 --decode | bash -se -- ' + args)
    command = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15',
               '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=4',
               '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=yes',
               '-o', 'UserKnownHostsFile=' + os.environ['SSH_KNOWN_HOSTS_FILE'],
               '-i', os.environ['SSH_KEY_FILE'], '-p', port, host,
               'bash -c ' + shlex.quote(bootstrap)]
    print(f'{mode}: {service} on {host} ~/docker-files/{folder}', flush=True)
    subprocess.run(command, input=token + '\n', text=True, check=True)


def main():
    configured = targets(os.environ.get('VIEWVEE_DEPLOY_TARGETS') or (ROOT / 'production.conf').read_text())
    if sys.argv[1:] == ['--validate']:
        return
    if sys.argv[1:]:
        raise ValueError('Unexpected arguments')
    revision = os.environ['DEPLOY_REVISION']
    if not re.fullmatch(r'[0-9a-f]{40}', revision):
        raise ValueError('Invalid deployment revision')
    for mode in ('check', 'deploy'):
        for target in configured:
            image = f'ghcr.io/specterinteractive/{SERVICES[target[0]]}:sha-{revision}'
            remote(target, image, mode)


if __name__ == '__main__':
    try:
        main()
    except (KeyError, ValueError, subprocess.CalledProcessError) as exc:
        sys.exit(f'Deployment failed: {exc}')
