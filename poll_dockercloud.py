#!/bin/env/python3
# -*- coding: utf-8 -*-
# poll_dockercloud.py - Poll dockercloud to get build status
#
# Copyright © 2017 Red Hat Inc.
# Written by Elad Alfassa <ealfassa@redhat.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
"""
poll_dockercloud - Poll dockercloud to get build status

Usage:
  ./poll_dockercloud.py <repo> <build_id>

Options:
  -h --help     Show this screen.

Set the DOCKERCLOUD_USER and DOCKERCLOUD_PASS environment variables for authenticatation.
"""
from __future__ import print_function, unicode_literals

import json
import os
import requests
import sys
from time import sleep
from docopt import docopt

if sys.version_info.major < 3:
    # hack to make this work with py2
    reload(sys)
    sys.setdefaultencoding('utf8')

DOCKERCLOUD_USER = os.getenv("DOCKERCLOUD_USER", None)
DOCKERCLOUD_PASS = os.getenv("DOCKERCLOUD_PASS", None)
AUTH = (DOCKERCLOUD_USER, DOCKERCLOUD_PASS)

BASE_URL = "https://cloud.docker.com"
REPO_URL_TEMPLATE = BASE_URL+"/api/repo/v1/repository/containermgmt/{0}/"
BUILD_URL = BASE_URL+"/api/build/v1/containermgmt/source/?image=containermgmt/{0}"


def poll_both_builds(repo, build_id):
    """ Poll both backend and frontend builds """
    state = False
    repo_url = REPO_URL_TEMPLATE.format(repo)
    print("Waiting for build to start")
    while state != "Building":
        sleep(10)
        response = requests.get(BUILD_URL.format(repo), auth=AUTH)
        response.raise_for_status()
        response_json = response.json()["objects"][0]
        state = response_json["state"]
        if state == "Success" and build_tag_exists(repo_url, build_id):
            raise SystemExit(0)
        print(".", end="")
        sys.stdout.flush()

    backend, frontend = None, None
    for partial_url in response_json['build_settings']:
        url = BASE_URL + partial_url
        build_response = requests.get(url, auth=AUTH)
        build_response.raise_for_status()
        if 'backend' in build_response.json()['tag']:
            backend = url
        else:
            frontend = url
    print("\nWaiting for backend build...")
    if poll_build_status(backend, build_id):
        print("\nBackend build complete! Waiting for frontend build...")
        poll_build_status(frontend, build_id, True, repo_url)


def poll_build_status(url, build_id, wait_for_tag=False, repo_url=None):
    """ Wait until a build is complete, and exit if it fails """
    state = "not started"
    while state in ["Building", "not started"]:
        sleep(5)
        response = requests.get(url, auth=AUTH)
        response.raise_for_status()
        print(".", end="")
        sys.stdout.flush()
        state = response.json()["state"]
        if wait_for_tag:
            if state == "Success" and not build_tag_exists(repo_url, build_id):
                state = "not started"
    if state == "Success":
        return True
    else:
        print("\nBuild failed!")
        print(json.dumps(response.json(), indent=4))
        raise SystemExit(1)


def build_tag_exists(repo_url, build_id):
    """ Check if the expected tag exists for the provided build ID """
    response = requests.get(repo_url, auth=AUTH)
    response.raise_for_status()
    if response.json()["state"] == "Success":
        # Build successful?
        # maybe it's the previous build, verify we have the latest tag
        for tag in response.json()["tags"]:
            if build_id in tag and "frontend" in tag:
                print("\nTag exists, build successful!")
                return True
    return False


def main():
    arguments = docopt(__doc__)
    if not DOCKERCLOUD_USER or not DOCKERCLOUD_PASS:
        raise SystemExit("Authentication required")
    poll_both_builds(arguments["<repo>"], arguments["<build_id>"])


if __name__ == "__main__":
    main()
