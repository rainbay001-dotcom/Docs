# Codex Investigation Mode

This note captures the practical way to ask Codex for investigation-style work:
explore first, verify claims with evidence, then answer with a detailed
explanation. There is no local Codex config knob named `investigation mode`.
Treat it as an explicit workflow instruction in the prompt.

## Current Local Config

`~/.codex/config.toml` currently uses:

```toml
model = "gpt-5.5"
model_reasoning_effort = "xhigh"
```

That is already the high-reasoning setup. The remaining control is how the task
is framed.

## Default Prompt

Use this prefix when you want investigation behavior:

```text
Investigation mode: do not answer from memory first. Explore the repo/files/logs/issues, run relevant searches or commands, verify assumptions, cite exact file paths/lines or evidence, then give a detailed explanation with findings, reasoning, and next steps.
```

Compact version:

```text
Use investigation mode: explore first, verify with evidence, then answer in detail.
```

## Codebase Investigation Prompt

```text
Investigate this deeply before answering. First inspect the relevant code paths with rg/sed/git/logs, identify the actual call chain or data flow, verify each claim against source, and only then answer. Include concrete file:line references, evidence, rejected hypotheses, and the final conclusion.
```

Expected behavior:

- Search the codebase before forming the conclusion.
- Prefer `rg`, `sed`, `git log`, `git show`, local docs, and targeted file reads.
- Cite exact files and line numbers when possible.
- Distinguish verified facts from inference.
- Record false leads when they matter to the final answer.

## Debugging Prompt

```text
Debug in investigation mode. Start by reproducing or locating the failure, gather logs and code context, list hypotheses, test them one by one, then explain the root cause and fix. Do not give a simple guess.
```

Expected behavior:

- Reproduce or locate the failure before guessing.
- Gather logs, stack traces, config, and version context.
- Build a small hypothesis list.
- Test hypotheses directly.
- End with root cause, fix, verification, and residual risk.

## Research / Docs Prompt

```text
Research mode: gather primary sources first, compare them, call out uncertainty, then write a structured detailed answer with citations and a concise conclusion.
```

Expected behavior:

- Use primary sources when possible.
- Compare sources instead of accepting the first plausible result.
- Include citations or exact local source references.
- Call out unknowns and confidence level.
- Produce a structured explanation, not just a short answer.

## Useful Trigger Words

These phrases reliably steer Codex toward investigation-style work:

- `investigate`
- `deep dive`
- `verify from source`
- `trace the call chain`
- `do not guess`
- `show evidence`
- `include rejected hypotheses`
- `write a detailed explanation`
- `create/update a doc with findings`

## Output Shape

A good investigation answer should usually include:

1. **Conclusion:** the short answer, after verification.
2. **Evidence:** commands, files, logs, source lines, issue comments, or docs.
3. **Reasoning:** why the evidence supports the conclusion.
4. **Rejected hypotheses:** only the ones that were plausible or costly.
5. **Next steps:** concrete follow-up actions or tests.

For implementation tasks, Codex should continue through code changes and
verification when feasible, rather than stopping at a proposal.

## When Not To Use It

Use a simple prompt for simple tasks. Investigation mode is most useful for:

- kernel, compiler, or distributed-system call-chain tracing
- performance anomalies
- CI/debugging failures
- source-backed technical explanations
- docs that must be defensible later
- anything where a guessed answer would create follow-up rework

