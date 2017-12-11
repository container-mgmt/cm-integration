# cm-integration
Builds ManageIQ container images with custom patches for integration testing

### Managing Pending PRs

To add or remove a PR, use `manageiq_prs.py`,

**Adding a PR**: `./manageiq_prs.py add <repo>/<pr>` (for example `add manageiq-api/76`)

**Removing a PR**: `./manageiq_prs.py remove <repo>/<pr>` (for example `remove manageiq-api/76`)

Please fork this repo, run the script to add a PR, and send the modified
json file as a PR on this repo.

The script will verify the PR is open and mergeable, and add it to the json file.

It should work with both python2 and python3, and requires `requests` and `docopt`.

If you get a 403 error from GitHub when running the script, that means you've
excceeded the anonymous API request limit. Export the `GH_USER` and `GH_PASS` environment variables
to make the script authenticate with GitHub. If you use 2-factor authenticatation you should
get [a personal access token](https://github.com/settings/tokens) instead of using your password.

### Building the Image

`./build.sh` will clone all the repos, apply all pending PRs, and push to our forks.
When it's done, it'll push the dockerfile to our fork of `manageiq-pods`, which should trigger
DockerHub to run the build.

Dependencies for the build script:
`dnf install git jq`
