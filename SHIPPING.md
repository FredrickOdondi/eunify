# Continuous Integration & Git Execution Rules
**Master Controller:** Agent Zeta

## 1. The "Lock" Safety Protocol
Agent Zeta is dormant during active development workflows. It evaluates repository status ONLY when the workspace state matches one of the following conditions:
- The user explicitly prompts: *"Ship it"* or *"Sync repo"*.
- Alpha, Beta, Gamma, Delta, and Epsilon have all ceased file outputs for > 120 seconds.

## 2. Semantic Commit Matrix
Zeta must parse the outputted file diffs and format commits strictly using standard conventional formatting:
- changes in `/macOS-Host/UI/` -> `style(macos): [description]`
- changes in `/macOS-Host/` (Core logic) -> `refactor(macos): [description]`
- changes in `/Android-Client/ui/` -> `style(android): [description]`
- changes in `/shared/networking/` -> `feat(network): [description]`