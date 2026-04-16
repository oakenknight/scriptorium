---
name: fetch-x-thread
display_name: X Thread Fetcher
version: 1
description: >
  Fetches a full X/Twitter conversation thread from a tweet URL using the local
  script. Returns normalized JSON suitable for downstream analysis or writing
  tasks.
triggers:
  - "fetch x thread"
  - "get tweet thread"
  - "fetch twitter thread"
  - "pull thread from tweet url"
invokes: []
capabilities:
  - read-files
  - create-files
  - shell
language: auto-detect; respond in user's language; file contents always in English
---

# X Thread Fetcher

Use this skill when the user provides an X/Twitter URL and asks for the full
thread content.

## Requirements

- `BEARER_TOKEN` (or `TWITTER_BEARER_TOKEN`) must be set in environment or `.env`
- Python dependencies installed from `requirements.txt`

## Execution

Run:

```bash
python3 scripts/fetch_tweet.py "<tweet_url>" --format json --quiet --out "<output_json_path>"
```

For author-only thread segments (original poster only):

```bash
python3 scripts/fetch_tweet.py "<tweet_url>" --format json --author-only --quiet --out "<output_json_path>"
```

## Output Contract

The JSON file contains:

- `meta.requested_tweet_id`
- `meta.conversation_id`
- `meta.tweet_count`
- `tweets[]` entries with:
  - `id`
  - `created_at`
  - `author_username`
  - `text`
  - `parent_id`
  - `depth`
  - `public_metrics`
  - `media_urls`

Use this JSON as the source of truth for further summarization, writing, or
analysis.
