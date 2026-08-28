---
name: create-skill
description: "Use when: turning a recurring workflow, debugging method, review checklist, or implementation pattern into a reusable SKILL.md for this workspace or for your personal setup."
---

# Create a reusable skill

## Purpose

Turn a proven workflow into a reusable skill that another agent or user can invoke on demand. This skill is for packaging multi-step processes, decision trees, and completion checks so they can be reused consistently.

## Use this skill when

- a task follows a repeatable multi-step workflow
- the process has logical branching or decision points
- there is a quality bar or completion checklist to standardize
- a team or individual wants to save a method in a reusable `SKILL.md`

## Scope

Before writing the skill, decide where it belongs:

- Workspace-scoped: use `.github/skills/<name>/SKILL.md` for project-specific workflows
- Personal-scoped: save in the user's customization folder for cross-workspace reuse

If the workflow is broad and applies across almost every task, prefer an instruction file instead of a skill.

## Workflow

### 1. Identify the recurring process

Review the conversation and extract the workflow being followed.

Look for:
- step-by-step actions
- repeated checks or review gates
- decision points where behavior changes
- quality criteria used to decide when work is done

### 2. Generalize the method

Convert the specific conversation into a reusable pattern.

Capture:
- the goal or outcome the skill produces
- the main sequence of actions
- the branch conditions or alternate paths
- the success checks to verify completion

### 3. Decide if a skill is appropriate

Use a skill only when the task is a multi-step workflow with bundled guidance.

Choose a skill instead of a prompt if:
- it involves more than one phase
- it depends on project conventions or checklists
- it benefits from reusable instructions and examples

Prefer a prompt when the workflow is a single focused action with inputs.

### 4. Draft the skill

Create the file in the appropriate location.

Include:
- valid YAML frontmatter with a clear `name` and `description`
- a purpose statement
- a short “when to use” section
- the workflow itself
- decision points and branching logic
- explicit completion or validation checks

### 5. Improve quality and reduce ambiguity

Before finalizing, check for weak spots:

- Is the trigger description specific enough for discovery?
- Are the steps concrete rather than vague?
- Are decision branches clear and testable?
- Are completion checks measurable?
- Is scope clearly workspace or personal?

### 6. Iterate and refine

Ask about the most ambiguous or uncertain components.

If the workflow is not yet clear, clarify:
- what final outcome the skill should produce
- whether it is for one workspace or for broader use
- whether it should be a checklist or a full workflow

### 7. Finalize and summarize

Once the draft is stable, summarize:
- what the skill produces
- when to use it
- example prompts that trigger it
- related customizations to create next

## Completion checklist

The skill is ready when all of the following are true:

- the workflow is clearly described
- there are explicit decision points or branching paths
- the outcome is concrete and reusable
- completion checks are included
- the file is saved in the correct location
- the description is specific enough to be discoverable

## Example prompts

- “Turn this debugging workflow into a reusable skill for the repo.”
- “Package our review checklist into a SKILL.md for team use.”
- “Create a personal skill for my standard implementation workflow.”
- “Generalize this multi-step validation process into a reusable workspace skill.”

## Related customizations to create next

- a workspace instruction for repo-wide conventions
- a targeted prompt for a single task type
- a custom agent for isolated multi-stage work
- a hook to enforce formatting or validation at lifecycle boundaries

## Best practices

- keep the skill focused on one reusable workflow
- make steps observable and testable
- use specific trigger phrases in the description
- avoid overloading a skill with unrelated guidance
- prefer path-specific scope unless the skill truly belongs everywhere
