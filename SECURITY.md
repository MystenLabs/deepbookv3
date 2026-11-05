# Security Policy

We appreciate your help keeping DeepBook secure. This policy covers the DeepBook packages in this repository: DeepBook v3 core, DeepBook Margin (margin trading and liquidation) and DeepBook Predict.

## Reporting a vulnerability

**Do not report security issues through GitHub issues, pull requests or Discord.**

- **Report through the Sui bug bounty on HackenProof:** https://hackenproof.com/programs/sui-protocol. The DeepBook v3 packages in this repository (DeepBook, DeepBook Margin, Account, Predict, Propbook, Sessions) are in scope, with DeepBook v3's own impact and payout tiers. DeepBook v2 is deprecated and out of scope.
- **Anything outside the HackenProof scope:** email security@mystenlabs.com.

Include the package id, module and function, a transaction or test that reproduces the issue, and the impact you believe it has. Do not test against mainnet funds you do not own.

## What to expect

| Step | Commitment |
|---|---|
| Acknowledgement | within 4 business hours (security@mystenlabs.com); HackenProof reports per the programme's response times |
| Initial severity assessment | within 72 hours |
| Fix or mitigation | Critical and High started immediately; pausing affected pools or margin markets first where possible |
| Public disclosure of a material incident | within 72 hours of confirmation; if disclosing then would put users at further risk (for example, a fix is not yet live), as soon as that risk has passed |
| Postmortem | within 14 days |
| Researcher disclosure | coordinated with the reporter, after a fix is live |

## Deployments

Mainnet packages are registered on MVR as `@deepbook/core`, `@deepbook/margin-trading`, `@deepbook/predict` and `@deepbook/predict-orders`; the remaining packages (including margin liquidation, Propbook, Account and Sessions) are being registered. The DeepBook app is app.deepbook.xyz (Predict at /predict). Upgrades are signed by the DeepBook multisig.
