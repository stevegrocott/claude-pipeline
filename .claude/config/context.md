# Project Context

This file is injected into agent prompts by the orchestrator to give agents
consistent knowledge of the project's patterns, conventions, and architecture.

Project teams should document here:
- Coding conventions and style rules specific to this codebase
- Architectural patterns agents should follow or avoid
- Key domain concepts and terminology
- Important file/directory conventions
- Any project-specific constraints (e.g., banned libraries, required patterns)

The orchestrator reads this file via `PLATFORM_CONTEXT_FILE` (configured in
`platform.sh`) and passes its contents to agents as supplemental context.
Leave this file empty or remove entries that no longer apply.
