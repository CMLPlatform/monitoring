# Contributing

Thank you for your interest in the observability stack. Bug reports, feature requests and
pull requests are welcome. Report vulnerabilities as [SECURITY.md](SECURITY.md) describes,
not in a public issue. Everyone taking part follows the
[Code of Conduct](CODE_OF_CONDUCT.md).

## Report a bug or ask for a feature

Open an [issue](https://github.com/CMLPlatform/monitoring/issues). For a bug, say what you
did, what you expected and what happened, with the version you used. A question the README
and docs don't answer is a gap in the docs: open an issue for it.

## Scope and response

One person maintains this stack, alongside other work. Expect a reply to an issue or pull
request within about two weeks.

Before a large pull request, such as a new service or a change to how projects connect,
open an issue and agree on the change there first. A small fix needs no issue. A pull
request outside what the stack sets out to do is closed with a link to this section.

## Set up and check

You need Docker with the Compose plugin and [`just`](https://github.com/casey/just).
`just hooks` installs the git hooks (with [prek](https://prek.j178.dev), which sets up the
Python environment for the citation hooks itself). `just check` runs the static checks and
validates every config, `just smoke` starts a throwaway copy of the stack and sends it
telemetry, and `just fmt` formats the YAML. CI runs `just lint`, `just validate` and
`just smoke`, plus `just infra-validate` when `infra/` changes. The
[Checks](../README.md#checks) table in the README lists every recipe.

## Write commits and pull requests

- **Commits** follow [Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/):
  `type(scope): summary`, in the imperative, lower case, with no period. Add a body only
  when the change needs one, with a bullet per logical chunk. The commit-msg hook refuses a
  first line that breaks the rule.
- **The pull request title** becomes the squash commit subject, so it follows the same rule.
- **The pull request body** starts from the [template](pull_request_template.md).
- **The changelog** ([CHANGELOG.md](../CHANGELOG.md)) follows
  [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/). Write each entry for
  the people who run the stack or connect a project to it, not as a commit subject. Mark
  breaking changes **Breaking**, and put upgrade steps first under the version.
- **The release notes** are that version's changelog section.

## Who maintains this

Simon van Lierde maintains the stack: reviews pull requests, merges them and makes
releases. The repository belongs to [CMLPlatform](https://github.com/CMLPlatform) on
GitHub. Only maintainers can merge to `main`. A new maintainer is added by an existing one,
by name in this section. If no maintainer can continue, the repository is archived with a
note in the README, and anyone may fork it under its license.
