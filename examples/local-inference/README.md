# Local Inference — Grammar-Constrained LLM Calls

Send prompts to a local llama.cpp server and get back guaranteed-valid JSON using GBNF grammar constraints. Reusable by any cron job, hook, or scheduled task that needs structured LLM output without paying for cloud API calls.

## The Problem

Cron jobs need structured output (JSON with specific fields) from LLM inference. Cloud API calls are expensive for routine tasks. Local models can hallucinate invalid JSON.

## The Solution

`local-infer-structured.sh` wraps a llama.cpp `/v1/chat/completions` call with:
- **GBNF grammar constraint** — the model can only generate tokens that match the grammar
- **Retry logic** — transient failures get one automatic retry
- **Telemetry** — every call logs latency, token counts, and throughput to a JSONL file

## Usage

```bash
# Direct prompt
local-infer-structured.sh \
  --prompt "Classify this email as urgent/normal/spam: ..." \
  --grammar grammars/classification.gbnf \
  --bot devops --job email-triage

# From file
local-infer-structured.sh \
  --prompt-file /tmp/analysis-prompt.txt \
  --grammar grammars/summary.gbnf

# From stdin
cat prompt.txt | local-infer-structured.sh --grammar grammars/output.gbnf
```

## Output

```json
{"ok": true, "content": "{\"classification\":\"urgent\"}", "usage": {"prompt_tokens": 150, "completion_tokens": 12}, "latency_ms": 2340, "attempts": 1}
```

## Telemetry

Each call appends a JSONL record to `~/.claude/state/telemetry/local-model-calls.jsonl`:

```json
{"ts":"2026-05-01T10:00:00.123Z","bot":"devops","backend":":8080","job":"email-triage","tokens_in":150,"tokens_out":12,"latency_ms":2340,"generation_ms":1800,"overhead_ms":540,"throughput_tok_per_ms":0.006667,"status":"ok"}
```

## Setup

1. Run a llama.cpp server: `llama-server -m model.gguf --port 8080`
2. Copy `local-infer-structured.sh` to `~/bin/` and `chmod +x`
3. Create GBNF grammar files for your use cases
4. Call from cron jobs, hooks, or scripts
