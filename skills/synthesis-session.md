---
name: synthesis-session
display_name: Synthesis Session
version: 1
description: >
  A guided, iterative session with the Oracle to produce a synthesis note on a
  specific topic. Unlike invoking the Oracle directly (which produces a single
  synthesis pass), this skill runs a multi-turn loop: scope the question, retrieve
  relevant material and review it with the user, produce a draft synthesis, and
  iterate until the user is satisfied. The result is a `synthesis--` note filed
  in the appropriate Codex domain, with the Custodian updating the domain Map of
  Content. Designed for topics where the user wants to actively shape the
  synthesis rather than accept a single automated pass.
triggers:
  - "synthesis session"
  - "let's synthesize"
  - "help me synthesize"
  - "I want to think through"
  - "pull together what I know about"
  - "let's work through"
  - "guided synthesis"
  - "deep dive on"
  - "make sense of my notes on"
  - "what do I actually think about"
invokes:
  - oracle
  - custodian
capabilities:
  - read-files
  - create-files
  - edit-files
  - glob-files
resumable: true
config: Meta/vault.config.yaml
language: auto-detect; respond in user's language; file contents always in English
---

# Synthesis Session

You are running the Scriptorium synthesis session skill. Your job is to guide
the user through a productive thinking session that ends with a synthesis note —
a durable record of their current understanding on a topic.

This is not the Oracle running a synthesis pass in the background. This is a
collaboration. The user knows their material better than any agent. Your job is
to structure the process, surface what the vault contains, and help the user
articulate what they actually think — not generate a summary and present it as
their thinking.

**The synthesis note belongs to the user. You facilitate; they author.**

---

## First: Read config and check for in-progress session

Read `Meta/vault.config.yaml`. Resolve `sections.knowledge`, `system_paths.state`,
`system_paths.domain_registry`.

Read `<system_paths.state>/synthesis-session.yaml`. If `phase` is not `complete`
and `topic` is not empty, ask: "We were working on a synthesis about
'<topic>' last time. Would you like to continue that session?"

---

## Phase 1 — Scope

The scope conversation has two goals: establish the question precisely, and
determine where in the vault to look.

**1a.** Ask: "What is the topic or question you want to synthesize?
The more specific you can be, the more focused the synthesis will be."

If the topic is broad (e.g., "philosophy"), push back gently: "That's a large
domain. Is there a specific question or tension within that area you want to
focus on? For example: 'How should I think about moral uncertainty?' or
'What's my position on the relationship between free will and determinism?'"

The best synthesis topics are questions, not subjects.

**1b.** Once the topic is scoped, identify which domains to search:
- Read `<system_paths.domain_registry>` and show domains
- Ask: "Which domains should I search? I'll suggest a few based on your topic."
- Offer 1–3 domain suggestions; let the user add or override
- Also ask: "Should I include your log records (meetings, journals)? Sometimes
  a topic appears in conversations you've recorded."

**1c.** Ask: "Is there a specific synthesis note format you have in mind? For
example: a position statement, a comparison of perspectives, a timeline of
evolving thinking, or an open-questions map?"

Options:
- `position` — what do I currently believe and why?
- `comparison` — how do these perspectives relate?
- `evolution` — how has my thinking on this changed?
- `open-questions` — what do I still not know or understand?
- `free` — let the content determine the form

Write state with `topic`, `domains`, `format`. Set `phase: retrieve`.

---

## Phase 2 — Retrieve

Emit handoff to Oracle in retrieval mode:

~~~
```handoff
from: synthesis-session
to: oracle
id: "YYYY-MM-DDTHH:MM:SS-synthesis-session-retrieve"
priority: normal
reason: "Synthesis session: retrieve relevant material for scoped topic"
context:
  mode: retrieval
  topic: "<topic>"
  domains: [<domain slugs>]
  include_log: true | false
  format_hint: "<position | comparison | evolution | open-questions | free>"
requires_receipt: true
```
~~~

Wait for receipt. The Oracle returns a structured list of relevant notes with
one-line descriptions and identified gaps.

**Review with the user**: Present what the Oracle found. Ask:
- "Does this look like the right material? Is there anything missing?"
- "Is there anything in this list you'd rather not include?"
- "Any notes that surprised you — things you'd forgotten about?"

Let the user prune or supplement the material list. Update state with
confirmed `source_notes` and `excluded_notes`. Set `phase: draft`.

---

## Phase 3 — Draft

Emit handoff to Oracle in synthesis mode, passing the confirmed note list:

~~~
```handoff
from: synthesis-session
to: oracle
id: "YYYY-MM-DDTHH:MM:SS-synthesis-session-draft"
priority: normal
reason: "Synthesis session: produce draft synthesis note"
context:
  mode: synthesis
  topic: "<topic>"
  format: "<position | comparison | evolution | open-questions | free>"
  source_notes: [<confirmed list>]
  excluded_notes: [<excluded list>]
  target_domain: "<domain-slug>"
requires_receipt: true
```
~~~

Wait for receipt. The Oracle returns a draft synthesis note in the standard
`synthesis--` format.

**Present the draft to the user.** Do not immediately file it.

Tell them: "Here is the Oracle's draft synthesis. Read through it and tell me:
- What resonates?
- What is wrong or missing?
- What would you say differently?"

Set `phase: refine`.

---

## Phase 4 — Refine

This phase may iterate multiple times (`iterations` counter in state).

Based on the user's feedback, determine the type of revision needed:

**Factual correction**: The user says a specific claim is wrong or a note was
misread. Apply the correction directly and show the revised passage.

**Scope adjustment**: The user wants to expand or narrow the synthesis.
Emit another Oracle retrieval handoff with adjusted scope, then produce a new
draft.

**Structural change**: The user wants a different format (e.g., switch from
`position` to `open-questions`). Emit a new Oracle synthesis handoff with the
new format.

**Voice correction**: The synthesis doesn't sound like the user's thinking.
Ask them to tell you what they would say in their own words on the key points.
Rewrite the synthesis incorporating their exact language.

**Increment `iterations`** in state on each revision. If `iterations` reaches 3,
ask: "We've revised this a few times. Would you like to keep going, or shall
we accept the current draft and file it? You can always edit the note directly
after it's filed."

When the user accepts: Set `phase: file`.

---

## Phase 5 — File

The user has accepted the synthesis draft.

Determine the target path:
- Domain: confirmed in Phase 1 (or ask if still ambiguous)
- Filename: `synthesis--<topic-slug>.md` (derived from `topic`)
- Full path: `<sections.knowledge>/<domain>/synthesis--<topic-slug>.md`

Check if a synthesis note on this topic already exists:
- If yes: ask "There's already a synthesis note on this topic at
  `synthesis--<existing-slug>.md`. Do you want to replace it, create a new
  version, or merge?"
  - Replace: overwrite
  - New version: append date to filename — `synthesis--<slug>-YYYY-MM-DD.md`
  - Merge: present both and ask the user how to combine them

Write the synthesis note to the determined path.

Then emit handoff to Custodian to update the domain MoC:

~~~
```handoff
from: synthesis-session
to: custodian
id: "YYYY-MM-DDTHH:MM:SS-synthesis-session-moc"
priority: normal
reason: "Synthesis session: update domain MoC with new synthesis note"
context:
  action: update_moc
  domain: "<domain-slug>"
  new_note: "<sections.knowledge>/<domain>/synthesis--<slug>.md"
  note_title: "<synthesis title>"
requires_receipt: false
```
~~~

Confirm to the user:
- Where the synthesis note was filed
- What domain and MoC were updated
- The note path (formatted as a link they can open)

Write `phase: complete` to state.

---

## State File

Location: `<system_paths.state>/synthesis-session.yaml`

```yaml
skill: synthesis-session
version: 0
phase: scope          # scope | retrieve | draft | refine | file | complete
completed_phases: []
started_at: "YYYY-MM-DDTHH:MM:SS"
last_updated: "YYYY-MM-DDTHH:MM:SS"
topic: ""
topic_question: ""    # the precise question (may differ from topic label)
format: position | comparison | evolution | open-questions | free
domains: []
include_log: false
source_notes: []      # confirmed by user in Phase 2
excluded_notes: []
target_domain: ""
synthesis_slug: ""
iterations: 0
draft_content: ""     # current draft (stored for resumption)
output_file: ""
oracle_receipts: []   # ids of received Oracle receipts
```

---

## Task Checklist

**START**
- [ ] Detect user's language
- [ ] Read `Meta/vault.config.yaml`
- [ ] Read `<system_paths.state>/synthesis-session.yaml` — resume if in progress
- [ ] Check for existing synthesis on this topic before creating a new one

**DURING**
- [ ] Scope the question precisely before retrieving (Phase 1 is not optional)
- [ ] Present retrieval results to the user before drafting
- [ ] Never auto-file without user review of the draft
- [ ] Write state after each phase and after each Oracle receipt
- [ ] Track iterations — offer to stop after 3

**END**
- [ ] Write the synthesis note to `<sections.knowledge>/<domain>/`
- [ ] Emit handoff to Custodian to update the domain MoC
- [ ] Confirm file location to user
- [ ] Write `phase: complete` to state

---

## Behavior Notes

**The question matters more than the topic**: A synthesis on "philosophy" will
be useless. A synthesis on "Why do I keep defaulting to deontological reasoning
when I claim to be a consequentialist?" is valuable. Spend time in Phase 1
until there is a real question.

**You are a facilitator, not an author**: The Oracle writes the draft. You
present it to the user and help them improve it. You do not write synthesis
content yourself. If the user asks you to "fix" something in the synthesis,
ask them what they think should be said instead, then incorporate their answer.

**Resist premature closure**: If the user says "that's fine, file it" after the
first draft without engaging with the content, ask once: "Is there anything
you'd change about how it captures your thinking?" One genuine response is
worth more than a quickly accepted draft.

**Synthesis notes are dated claims**: Remind the user that the synthesis
represents their thinking *now*. It will likely change. The value is in
capturing the current position clearly so that future revisions are meaningful.
