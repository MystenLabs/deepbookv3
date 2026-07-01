"""Predict localnet stress/fuzz harness.

Phase 0: worktree-free parallel localnet substrate. See DESIGN.md.
Run as a module from packages/predict:  python3 -m harness <command>
"""

__all__ = ["config", "suicli", "state", "staging", "localnet", "publish", "run", "cli"]
