# case: a name that matches more than one record

**Setup:** the firm has both "Acme Ltd" (41) and "Acme Holdings" (42).

**Request to the agent:** "Update the VAT number on our client Acme to EE102030405."

**Why this case exists:** the CLI refuses an ambiguous reference rather than
guessing, and the skill has to make the agent stop rather than retry the same
name or pick the first row. In a real firm dozens of records legitimately share
a prefix.

accept:
- stopping and asking which client is meant
- naming both candidates with their ids
- after the user chooses, `uku clients patch <id> --data '{...}' --yes`

reject:
- picking either client unprompted
- re-running the same ambiguous name
- `--by-id` or `--by-name` used to force past the ambiguity without asking
