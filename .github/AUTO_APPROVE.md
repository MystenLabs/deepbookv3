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
- The Codex review comment must be published successfully before approval.
- Minor Codex findings do not prevent bot approval.
- If a retry on the same commit finds significant issues after the App already
  approved it, the workflow dismisses that approval. If GitHub refuses the
  dismissal, the workflow replaces it with `REQUEST_CHANGES`.
- Significant Codex findings, Codex failures, and approval failures send a
  top-level `@here` notification in Slack.
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
`drop-sudo` safety strategy. A separate trusted workflow step formats the
structured output and posts the advisory pull request comment.

Codex gates the bot's approval. A fresh significant result does not submit a
`REQUEST_CHANGES` review. On a significant retry of an already approved commit,
`REQUEST_CHANGES` is used only as a fallback when GitHub refuses to dismiss the
existing App approval; a human reviewer may dismiss that fallback review after
deciding how to proceed.

## Slack

Create or reuse a Slack App, enable Incoming Webhooks, and add a webhook for the
destination channel. Configure:

| Type | Name | Value |
| --- | --- | --- |
| Secret | `SLACK_WEBHOOK_URL` | Complete `https://hooks.slack.com/services/...` URL |

The webhook is tied to its configured channel. The workflow posts the request,
final Codex result, and any later approval invalidation as separate top-level
messages containing the PR link and commit SHA. Incoming webhooks do not return
the message timestamp needed to create a thread without an additional Slack API
or Events integration.

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
3. Confirm a review with no significant findings is posted before approval.
4. Confirm a review with a significant finding leaves the pull request
   unapproved and sends an `@here` Slack alert.
5. Reapply the label to an already approved commit and confirm a significant
   retry dismisses or replaces the existing App approval.
6. Confirm a comment publication failure does not submit bot approval.
7. Confirm Slack gets one request message and one final result message.
8. Push another commit and confirm it is not automatically re-approved.
   Confirm the old approval is dismissed or replaced with `REQUEST_CHANGES`.
9. Apply the label to a PR from a non-member and confirm authorization fails.

The GitHub Actions workflow uses `pull_request_target` so it can access secrets.
It must continue checking out only the trusted base commit and must never run
code from the pull request branch.
