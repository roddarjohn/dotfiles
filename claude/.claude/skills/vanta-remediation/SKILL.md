---
name: vanta-remediation
description: >-
  Workflow for remediating Vanta compliance test findings in an
  infrastructure-as-code repository. Load this when Rodda asks about Vanta
  failing tests, outstanding compliance tests, a remediation report, or a
  PR fixing them.
---

# Vanta remediation

Loop: check Vanta for failing tests, write up what needs to be done, then
fix the ones that need fixing.

1. **Check** — pull failing tests from the Vanta API, including the failing
   entity lists, so each failure maps to a concrete resource.
2. **Triage** — split into: fixable in the infra repo, fixable elsewhere,
   or a Vanta-side action. Verify each against the actual code before
   claiming it is fixable here.
3. **Report** — write the triage to a plan file, with a status per test.
   Items that are policy or workflow trade-offs go to Rodda first; items
   that are not code fixes are surfaced, never silently dropped.
4. **Fix** — build the in-repo fixes as a PR against the infra repo, one
   unit of work at a time, letting CI be the real validator.
5. **Revise** — apply Rodda's feedback; keep the plan file's status current
   as the durable record of what was fixed, skipped, or delegated.
