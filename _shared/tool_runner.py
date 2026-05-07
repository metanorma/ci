"""Shared utilities for tool setup composite actions.

Provides platform detection and command execution used by all *-setup-action
composite actions in this repository.
"""

import os
import sys
import platform
import subprocess


def os_release():
    """Detect Linux distribution from /etc/os-release.

    Returns a dict of key=value pairs from /etc/os-release, or an empty dict
    on non-Linux platforms or when the file is unreadable.
    """
    try:
        return platform.freedesktop_os_release()
    except AttributeError:
        pass
    except OSError:
        return {}

    properties = {}
    try:
        with open("/etc/os-release", "r") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    key, value = line.split("=", 1)
                    properties[key] = value.strip('"')
    except (IOError, OSError):
        pass
    return properties


def get_platform_name():
    """Return normalized platform name for tool dispatch.

    Returns one of: 'Darwin', 'Windows', 'Ubuntu', 'Linux'.
    'Ubuntu' is distinguished from generic Linux because GitHub-hosted
    Ubuntu runners use apt-based package management.
    """
    info = os_release()
    if info.get("ID") == "ubuntu":
        return "Ubuntu"
    return platform.system()


def run_commands(cmds):
    """Execute a list of shell commands, aborting on first failure."""
    for cmd in cmds:
        print(f"> {cmd}")
        sys.stdout.flush()
        result = subprocess.run(cmd, shell=True)
        if result.returncode != 0:
            print(f"Command FAILED: {cmd}")
            sys.exit(1)
