# Auto-approval setup

The `auto-approve` workflow reviews a pull request with Codex when its author is
an active member of `MystenLabs/defi-eng`. It submits the GitHub App approval
only when Codex reports no significant findings, then records the result in
Slack.

## Behavior

- The workflow only handles open, non-draft pull requests targeting the
  repository's default branch.
- Authorization is based on the pull request author's live membership in
  `MystenLabs/defi-eng`.
- Approval is bound to the head commit that was current when the label was
  applied.
- The `auto-approve` label is removed after the workflow attempt, whether or
  not approval is submitted. A later attempt requires the label to be applied
  again.
- A push after auto-approval invalidates the bot review. The workflow first
  tries to dismiss the old approval and falls back to `REQUEST_CHANGES` if the
  repository does not let the App dismiss protected-branch reviews.
- Significant Codex findings, a missing or failed Codex review, and invalid
  Codex output prevent the bot from approving the pull request.
- Codex output is validated against the complete expected schema before it can
  authorize approval.
- The public Codex status comment must be published successfully before
  approval. It reports only whether significant findings exist; summaries,
  locations, and descriptions are sent only to Slack.
- Each label-triggered run publishes its own Codex status comment, even when
  the head commit is unchanged. Rerunning the same Actions run updates that
  run's comment instead of creating a duplicate.
- Minor Codex findings do not prevent bot approval.
- If any retry cannot establish a valid, published Codex result with no
  significant findings, the workflow dismisses an existing App approval for
  that commit. This includes authorization failures, missing configuration,
  Codex failures, invalid output, significant findings, and comment publication
  failures. If GitHub refuses the dismissal, the workflow replaces the approval
  with `REQUEST_CHANGES`.
- If a later clean retry follows `REQUEST_CHANGES`, the App submits a new
  approval because decisions use its latest review for that commit.
- Significant Codex findings mention only the mapped Slack account for the pull
  request owner. Other workflow failures do not use broad Slack mentions.
- Pull request text is escaped before it is copied to Slack so it cannot inject
  mentions.

## GitHub App

The repository `GITHUB_TOKEN` cannot read private organization team
membership. Create one GitHub App for both target repositories and configure
these permissions:

Organization permissions:

- Members: Read-only

Repository permissions:

- Contents: Read and write
- Issues: Read and write
- Metadata: Read-only
- Pull requests: Read and write

`Contents: Read and write` is required for the GitHub App's approval to count
as a qualified review for protected branches. The workflow does not use the
installation token to modify repository contents.

The App does not need webhooks. Install it only on the two repositories that
use auto-approval, then create a private key.

Configure these values as organization-level values restricted to those two
repositories, or configure them independently in each repository:

| Type | Name | Value |
| --- | --- | --- |
| Secret | `AUTO_APPROVE_APP_CLIENT_ID` | The GitHub App client ID |
| Secret | `AUTO_APPROVE_APP_PRIVATE_KEY` | The complete PEM private key |

The workflow narrows its short-lived installation token to the API permissions
used by each job. `Contents: Read and write` remains enabled on the App
installation so GitHub treats the App as a qualified reviewer.

## Codex

Create an OpenAI Platform API key and configure:

| Type | Name | Value |
| --- | --- | --- |
| Secret | `OPENAI_API_KEY` | OpenAI API key used by Codex GitHub Action |

The Codex GitHub Action uses API billing; a personal Codex or ChatGPT
subscription is not used by this workflow.

Codex is deliberately isolated from GitHub write access. The workflow checks
out only the trusted base commit, downloads the pull request diff as untrusted
review input, and runs Codex with the `:read-only` permission profile and the
`drop-sudo` safety strategy.

The official Codex Action initializes the authenticated runtime with a harmless
prompt. The actual review runs in a separate silenced `codex exec` process that
writes its structured result to a runner-temporary file. Trusted workflow steps
read that file directly; they do not place review output in Action outputs,
environment variables, artifacts, or public logs. The file is removed after the
Slack notification attempt.

The public pull request comment contains only the commit and gate status. Full
Codex summaries and findings are posted only to Slack.

Codex gates the bot's approval. A fresh blocked result does not submit a
`REQUEST_CHANGES` review. On a blocked retry of an already approved commit,
`REQUEST_CHANGES` is used only as a fallback when GitHub refuses to dismiss the
existing App approval; a human reviewer may dismiss that fallback review after
deciding how to proceed.

## Slack

Create or reuse a Slack App, enable Incoming Webhooks, and add a webhook for the
destination channel. Configure:

| Type | Name | Value |
| --- | --- | --- |
| Secret | `SLACK_WEBHOOK_URL` | Complete `https://hooks.slack.com/services/...` URL |
| Secret | `SLACK_USER_MAP` | JSON object mapping lowercase GitHub logins to Slack `U...` or `W...` member IDs |

The webhook is tied to its configured channel. The workflow posts the request,
final Codex result, and any later approval invalidation as separate top-level
messages containing the PR link and commit SHA. Incoming webhooks do not return
the message timestamp needed to create a thread without an additional Slack API
or Events integration.

The initial request identifies the `PR owner` and `Auto-approval requested by`
using GitHub logins without sending a Slack mention. When Codex reports
significant findings, the final message mentions only the mapped PR owner using
Slack's `<@USER_ID>` syntax. A missing or invalid mapping leaves the GitHub login
visible but does not fall back to `@here` or `@channel`.

## Repository label

Create the label after the workflow has been merged and all required GitHub
App credentials are configured:

```bash
gh label create auto-approve \
  --repo MystenLabs/deepbookv3 \
  --description "Request Codex-gated bot approval" \
  --color 0E8A16
```

## Verification

Use a small test pull request authored by a `defi-eng` member:

1. Apply `auto-approve` and confirm Codex completes before the custom GitHub
   App submits the approval.
2. Confirm the label is removed and the approval references the expected SHA.
3. Confirm a status with no significant findings is posted before approval and
   does not expose the Codex summary or findings.
4. Confirm a review with a significant finding leaves the pull request
   unapproved, keeps finding details out of the pull request and Actions log,
   and mentions only the mapped PR owner in Slack.
5. Reapply the label to an already approved commit and confirm a significant
   retry dismisses or replaces the existing App approval.
6. Confirm failed Codex execution, invalid output, and comment publication
   failure also dismiss or replace an existing App approval.
7. Reapply the label without changing the commit and confirm the new Codex
   status is published in a new comment.
8. Confirm a clean retry after fallback `REQUEST_CHANGES` submits a newer App
   approval.
9. Confirm a comment publication failure does not submit bot approval.
10. Confirm Slack gets one request message and one final result message.
11. Push another commit and confirm it is not automatically re-approved.
   Confirm the old approval is dismissed or replaced with `REQUEST_CHANGES`.
12. Apply the label to a PR from a non-member and confirm authorization fails.

The GitHub Actions workflow uses `pull_request_target` so it can access secrets.
It must continue checking out only the trusted base commit and must never run
code from the pull request branch.
