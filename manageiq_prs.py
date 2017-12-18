#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# manageiq_prs.py - Manage pending ManageIQ PR for integration with the automated docker build
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
manageiq_prs: Manage ManageIQ pending PRs for the docker build

Usage:
  ./manageiq_prs.py add <repo>/<pr>
  ./manageiq_prs.py remove <repo>/<pr>
  ./manageiq_prs.py check [<repo>/<pr>]
  ./manageiq_prs.py remove_merged
  ./manageiq_prs.py printlinks
  ./manageiq_prs.py -h | --help

Options:
  -h --help     Show this screen.

Set the GIT_USER and GIT_PASSWORD environment variables if you need authentication.
"""

from __future__ import print_function, unicode_literals
import collections
import json
import os
import requests
import sys
from docopt import docopt
from tabulate import tabulate
API_URL = "https://api.github.com/repos/ManageIQ/{repo}/pulls/{id}"
PRS_JSON = "pending-prs-unstable.json"

# Support basic github authentication from environment variables
GH_USER = os.getenv("GIT_USER", None)
GH_PASS = os.getenv("GIT_PASSWORD", None)
GH_AUTH = (GH_USER, GH_PASS) if GH_USER and GH_PASS else None

if sys.version_info.major < 3:
    # hack to make this work with py2
    reload(sys)
    sys.setdefaultencoding('utf8')


def color(string, color):
    """ Return the input string with color escape codes """
    if not sys.stdout.isatty():
        # Don't output colors if it's not a TTY
        return string

    if color == "red":
        code = '91'
    elif color == "green":
        code = '92'
    elif color == 'yellow':
        code = '93'

    return "\033[{code}m{string}\033[0m".format(code=code, string=string)


def get_pr(repo, pr):
    """ Get information about a PR from the GitHub API """
    response = requests.get(API_URL.format(repo=repo, id=pr), auth=GH_AUTH)
    response.raise_for_status()  # Properly fail if there was an error
    return response.json()


def get_pr_status(pr_info):
    """ Get a PR's status as a simple string: "open", "closed", or "merged" """
    if pr_info["merged"]:
        return "merged"
    if pr_info["state"] == "open":
        return "open"
    else:
        return "closed"


def check_file(current):
    """ Verify existing PRs, return 0 if the file is okay """
    ret = 0
    for repo, prs in current.items():
        for pr in prs:
            info = get_pr(repo, pr)
            status = get_pr_status(info)
            if status in ["merged", "closed"]:
                ret = 1
                status = color(status.upper(), 'red')
            else:
                if not info["mergeable"]:
                    status = color("NOT MERGEABLE", 'red')
                else:
                    status = color(status.upper(), 'green')
            status_line = "{status}:\t{repo} #{pr} (by @{user}) - {title}"
            status_line = status_line.format(status=status, repo=repo, pr=pr,
                                             user=info['user']['login'],
                                             title=info['title'])
            print(status_line)
    print()
    if ret == 0:
        print(color("✔️  all good", 'green') + ' 👍')
    else:
        print(color("❌  problems found", 'red'))
    return ret


def remove_merged(current):
    """ Remove all merged PRs from the json file """
    removed = 0
    warnings = 0
    for repo, prs in current.items():
        to_remove = set()
        for pr in prs:
            info = get_pr(repo, pr)
            status = get_pr_status(info)
            if status == "merged":
                to_remove.add(pr)
                removed += 1
                status = color('❌ ' + status.upper(), 'red')
            elif status == "closed":
                status = color('⚠ ' + status.upper(), 'yellow') + " warning"
                warnings += 1
            else:
                status = color('✔️ ' + status.upper(), 'green')
            status_line = "{status}:\t{repo} #{pr} (by @{user}) - {title}"
            status_line = status_line.format(status=status, repo=repo, pr=pr,
                                             user=info['user']['login'],
                                             title=info['title'])
            print(status_line)
        current[repo] = list(filter(lambda item: item not in to_remove, prs))

    with open(PRS_JSON, 'w') as f:
        json.dump(current, f, indent=4)

    print("Removed: {removed} PRs".format(removed=removed))
    if warnings:
        print(color("⚠ {warnings} warnings".format(warnings=warnings)))

    return 0 if not warnings else 1


def main():
    arguments = docopt(__doc__)
    with open(PRS_JSON, 'r') as f:
        current = json.load(f, object_pairs_hook=collections.OrderedDict)

    if arguments["check"]:
        # Check current json
        raise SystemExit(check_file(current))
    elif arguments["remove_merged"]:
        # Remove merged PRs from the json file
        raise SystemExit(remove_merged(current))
    elif arguments["printlinks"]:
        # Print links and titles for all PRs in the file
        table = []
        for repo, prs in current.items():
            for pr in prs:
                info = get_pr(repo, pr)
                table.append([info['html_url'], '@'+info['user']['login'],
                              info['title']])
        print(tabulate(table, tablefmt="simple"))
    elif arguments["remove"] or arguments["add"]:
        repo, pr = arguments['<repo>/<pr>'].split('/', 1)
        info = get_pr(repo, pr)

        verb = "Adding:" if arguments["add"] else "Removing:"
        pr_line = "{verb} {repo} #{pr} (by @{user}) - {title}"

        pr_line = pr_line.format(verb=verb, repo=repo, pr=pr,
                                 user=info['user']['login'],
                                 title=info['title'])
        print(pr_line)
        pr = int(pr)
        if arguments["remove"]:
            if pr not in current[repo]:
                exitstr = "❌  {repo} PR #{pr} was not in the file"
                exitstr = exitstr.format(repo=repo, pr=pr)
                raise SystemExit(exitstr)

            current[repo].remove(pr)  # remove the PR
        else:
            exitstr = None
            # Check if the PR can be added
            if not info["mergeable"]:
                exitstr = "❌  {repo} PR #{pr} is not mergeable"
            if info["merged"]:
                exitstr = "❌  {repo} PR #{pr} is already merged"
            if info["state"] != "open":
                exitstr = "❌  {repo} PR #{pr} is not open"
            if pr in current[repo]:
                exitstr = "❌  {repo} PR #{pr} is already listed"

            if exitstr:
                # error found, exit
                exitstr = exitstr.format(repo=repo, pr=pr)
                raise SystemExit(color("FAILED: ", 'red') + exitstr)
            current[repo].append(pr)  # Add the pr to the list

        with open(PRS_JSON, 'w') as f:
            json.dump(current, f, indent=4)

        # success
        verb = "added" if arguments["add"] else "removed"
        msg = "✔️  {repo} PR #{pr} was {verb} 👍".format(repo=repo, pr=pr,
                                                        verb=verb)
        print(color("OK: ", "green") + msg)

if __name__ == "__main__":
    main()
