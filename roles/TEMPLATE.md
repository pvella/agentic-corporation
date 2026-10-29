# Role template — custom agent

Copy this file's structure into a new `roles/catalog.json` entry (or start from `roles/TEMPLATE.json`). Keep **full_description** complete — do not summarise.

```markdown
### NN. Your Role Title Agent

**Purpose and scope** — One or two sentences: what this agent does, and what it must not do.

**Human owner and applicability** — Who is accountable; when the role applies.

**Key responsibilities**
- Responsibility one.
- Responsibility two.

**Outputs and cadence** — What it produces and how often.

**Tools, data and access** — Approved tools, data scope, least-privilege notes.

**Decision rights and escalation** — Routine actions vs human approval; escalation triggers.

**Required capabilities and acceptance tests** — Skills and how to verify them.

**Performance measures** — How quality and safety are judged.

**Handoffs and example workflow** — A short end-to-end example.
```

## catalog.json fields

| Field | Required | Notes |
|-------|----------|-------|
| `id` | yes | Stable slug, e.g. `role_51_my_custom_agent` |
| `title` | yes | Display title |
| `default_name` | no | Hire name default |
| `category` | yes | Must match a categories[] entry (or add one) |
| `department` | yes | Usually same as category |
| `room` | yes | `executive` / `engineering` / `product_design` / `operations` / `finance` / `special_projects` |
| `color` | no | Hex chip colour |
| `summary` | yes | One-line card blurb (can be first sentence of purpose) |
| `purpose` | yes | Purpose and scope text |
| `responsibilities` | yes | Array of strings |
| `tools` | no | Short tool name list |
| `tools_text` | yes | Verbatim tools section |
| `repos` | no | Default repos, e.g. `["."]` |
| `reports_to` | yes | Human owner / reporting line |
| `full_description` | yes | **Verbatim** markdown for the whole JD |
| `example` | no | `false` for real roles |
