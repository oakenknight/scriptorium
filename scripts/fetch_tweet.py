#!/usr/bin/env python3
"""
fetch_tweet.py - Fetch a tweet thread by URL using the Twitter/X API v2.

Usage:
    python fetch_tweet.py <tweet_url>
    python fetch_tweet.py https://x.com/user/status/1234567890 --format json --out thread.json

Requires:
    pip install requests
    BEARER_TOKEN or TWITTER_BEARER_TOKEN env var
    (get one at: https://developer.twitter.com/en/portal/dashboard)
"""

import os
import re
import sys
import json
import time
import argparse
from urllib.parse import unquote
import requests
from dotenv import load_dotenv


TWEET_FIELDS = ",".join([
    "id",
    "text",
    "author_id",
    "created_at",
    "public_metrics",
    "attachments",
    "entities",
    "lang",
    "possibly_sensitive",
    "conversation_id",
    "referenced_tweets",
    "reply_settings",
    "source",
])

EXPANSIONS = ",".join([
    "author_id",
    "referenced_tweets.id",
    "attachments.media_keys",
])

USER_FIELDS = "id,name,username,public_metrics,verified,description"
MEDIA_FIELDS = "media_key,type,url,preview_image_url,public_metrics"
BASE_URL = "https://api.x.com/2"

# Load variables from project .env file if present.
load_dotenv()


def extract_tweet_id(url: str) -> str:
    """Extract tweet ID from a twitter.com or x.com URL."""
    match = re.search(r"/status/(\d+)", url)
    if not match:
        raise ValueError(f"Could not extract tweet ID from URL: {url}")
    return match.group(1)


def _parse_error_detail(response: requests.Response) -> str:
    """Extract a useful error detail from API response JSON."""
    try:
        payload = response.json()
    except ValueError:
        return response.text

    if not isinstance(payload, dict):
        return response.text

    parts = [payload.get("title"), payload.get("detail"), payload.get("reason")]
    parts = [part for part in parts if part]
    if parts:
        return " | ".join(parts)
    return response.text


def _request_with_retries(url: str, headers: dict, params: dict, retries: int = 3) -> requests.Response:
    """Execute GET requests with retry/backoff for transient errors."""
    backoff_seconds = 1
    last_response = None
    last_exception = None

    for attempt in range(retries + 1):
        try:
            response = requests.get(url, headers=headers, params=params, timeout=20)
            last_response = response
            if response.status_code not in {429, 500, 502, 503, 504}:
                return response
            if attempt == retries:
                return response
        except requests.exceptions.RequestException as exc:
            last_exception = exc
            if attempt == retries:
                break

        time.sleep(backoff_seconds)
        backoff_seconds *= 2

    if last_response is not None:
        return last_response
    raise RuntimeError(f"Network/API request failed: {last_exception}")


def _handle_response_errors(response: requests.Response, not_found_msg: str):
    """Raise clear Python exceptions for API error responses."""
    if response.status_code == 200:
        return

    err_detail = _parse_error_detail(response)
    if response.status_code == 401:
        raise PermissionError(f"Invalid or expired bearer token. API says: {err_detail}")
    if response.status_code == 403:
        raise PermissionError(f"Access forbidden - check your app's access level. API says: {err_detail}")
    if response.status_code == 404:
        raise ValueError(not_found_msg)
    raise RuntimeError(f"API error {response.status_code}: {err_detail}")


def fetch_tweet(tweet_id: str, bearer_token: str) -> dict:
    """Fetch one tweet by ID from the Twitter API v2."""
    headers = {"Authorization": f"Bearer {bearer_token}"}
    params = {
        "tweet.fields": TWEET_FIELDS,
        "expansions": EXPANSIONS,
        "user.fields": USER_FIELDS,
        "media.fields": MEDIA_FIELDS,
    }
    url = f"{BASE_URL}/tweets/{tweet_id}"
    response = _request_with_retries(url, headers, params, retries=3)
    _handle_response_errors(response, f"Tweet {tweet_id} not found (deleted or private).")

    return response.json()


def fetch_conversation(conversation_id: str, bearer_token: str) -> dict:
    """Fetch all tweets from a conversation via recent search."""
    headers = {"Authorization": f"Bearer {bearer_token}"}
    url = f"{BASE_URL}/tweets/search/recent"
    all_tweets = []
    user_map = {}
    media_map = {}
    next_token = None

    while True:
        params = {
            "query": f"conversation_id:{conversation_id}",
            "max_results": 100,
            "tweet.fields": TWEET_FIELDS,
            "expansions": EXPANSIONS,
            "user.fields": USER_FIELDS,
            "media.fields": MEDIA_FIELDS,
        }
        if next_token:
            params["next_token"] = next_token

        response = _request_with_retries(url, headers, params, retries=3)
        _handle_response_errors(response, f"Conversation {conversation_id} not found.")
        payload = response.json()

        all_tweets.extend(payload.get("data", []))
        includes = payload.get("includes", {})
        for user in includes.get("users", []):
            user_map[user["id"]] = user
        for media in includes.get("media", []):
            media_map[media["media_key"]] = media

        meta = payload.get("meta", {})
        next_token = meta.get("next_token")
        if not next_token:
            break

    return {
        "data": all_tweets,
        "includes": {
            "users": list(user_map.values()),
            "media": list(media_map.values()),
        },
        "meta": {"result_count": len(all_tweets)},
    }


def format_thread(data: dict) -> str:
    """Pretty-print a whole thread in chronological order."""
    tweets = data.get("data", [])
    includes = data.get("includes", {})
    if not tweets:
        return "No thread tweets returned."

    tweets.sort(key=lambda t: t.get("created_at", ""))

    # Resolve author and media lookups
    users = {u["id"]: u for u in includes.get("users", [])}
    media_lookup = {m["media_key"]: m for m in includes.get("media", [])}
    tweet_map = {tweet["id"]: tweet for tweet in tweets}

    def parent_id_for(tweet: dict):
        for ref in tweet.get("referenced_tweets", []):
            if ref.get("type") == "replied_to":
                return ref.get("id")
        return None

    depth_cache = {}

    def depth(tweet_id: str) -> int:
        if tweet_id in depth_cache:
            return depth_cache[tweet_id]
        tweet = tweet_map.get(tweet_id)
        if not tweet:
            depth_cache[tweet_id] = 0
            return 0
        parent_id = parent_id_for(tweet)
        if not parent_id or parent_id not in tweet_map:
            depth_cache[tweet_id] = 0
            return 0
        d = min(depth(parent_id) + 1, 8)
        depth_cache[tweet_id] = d
        return d

    lines = []
    lines.append("=" * 72)
    lines.append(f"Thread tweets fetched: {len(tweets)}")
    lines.append("=" * 72)
    lines.append("")

    for tweet in tweets:
        author = users.get(tweet.get("author_id"), {})
        indent = "  " * depth(tweet["id"])
        lines.append(f"{indent}@{author.get('username', 'unknown')} ({author.get('name', '')})")
        lines.append(f"{indent}{tweet.get('created_at', '')}  id={tweet.get('id', '')}")
        lines.append(f"{indent}{tweet.get('text', '')}")

        metrics = tweet.get("public_metrics", {})
        if metrics:
            lines.append(
                f"{indent}likes={metrics.get('like_count', 0):,} "
                f"retweets={metrics.get('retweet_count', 0):,} "
                f"replies={metrics.get('reply_count', 0):,}"
            )

        media_keys = []
        attachments = tweet.get("attachments", {})
        if isinstance(attachments, dict):
            media_keys = attachments.get("media_keys", [])
        for media_key in media_keys:
            media = media_lookup.get(media_key, {})
            mtype = media.get("type", "unknown")
            murl = media.get("url") or media.get("preview_image_url", "")
            lines.append(f"{indent}media[{mtype}] {murl}")
        lines.append("")

    lines.append("=" * 72)

    return "\n".join(lines)


def _parent_id_for(tweet: dict) -> str | None:
    for ref in tweet.get("referenced_tweets", []):
        if ref.get("type") == "replied_to":
            return ref.get("id")
    return None


def normalize_thread(data: dict, conversation_id: str, requested_tweet_id: str) -> dict:
    """Create stable, skill-friendly JSON output."""
    tweets = data.get("data", [])
    includes = data.get("includes", {})
    tweets.sort(key=lambda t: t.get("created_at", ""))
    users = {u["id"]: u for u in includes.get("users", [])}
    media_lookup = {m["media_key"]: m for m in includes.get("media", [])}
    tweet_map = {tweet["id"]: tweet for tweet in tweets if tweet.get("id")}

    depth_cache = {}

    def depth(tweet_id: str) -> int:
        if tweet_id in depth_cache:
            return depth_cache[tweet_id]
        tweet = tweet_map.get(tweet_id)
        if not tweet:
            depth_cache[tweet_id] = 0
            return 0
        parent_id = _parent_id_for(tweet)
        if not parent_id or parent_id not in tweet_map:
            depth_cache[tweet_id] = 0
            return 0
        d = min(depth(parent_id) + 1, 8)
        depth_cache[tweet_id] = d
        return d

    normalized_tweets = []
    for tweet in tweets:
        author = users.get(tweet.get("author_id"), {})
        media_urls = []
        attachments = tweet.get("attachments", {})
        if isinstance(attachments, dict):
            for media_key in attachments.get("media_keys", []):
                media = media_lookup.get(media_key, {})
                media_urls.append(media.get("url") or media.get("preview_image_url") or "")
        media_urls = [url for url in media_urls if url]

        normalized_tweets.append({
            "id": tweet.get("id"),
            "conversation_id": tweet.get("conversation_id"),
            "created_at": tweet.get("created_at"),
            "author_id": tweet.get("author_id"),
            "author_username": author.get("username"),
            "author_name": author.get("name"),
            "text": tweet.get("text", ""),
            "parent_id": _parent_id_for(tweet),
            "depth": depth(tweet.get("id", "")),
            "public_metrics": tweet.get("public_metrics", {}),
            "media_urls": media_urls,
            "lang": tweet.get("lang"),
        })

    return {
        "meta": {
            "requested_tweet_id": requested_tweet_id,
            "conversation_id": conversation_id,
            "tweet_count": len(normalized_tweets),
        },
        "tweets": normalized_tweets,
    }


def render_markdown(thread_json: dict) -> str:
    """Render normalized thread JSON as markdown."""
    lines = []
    meta = thread_json.get("meta", {})
    lines.append(f"# Thread {meta.get('conversation_id', '')}")
    lines.append("")
    lines.append(f"- Requested tweet: `{meta.get('requested_tweet_id', '')}`")
    lines.append(f"- Tweets fetched: `{meta.get('tweet_count', 0)}`")
    lines.append("")
    lines.append("---")
    lines.append("")

    for item in thread_json.get("tweets", []):
        depth = item.get("depth", 0)
        indent = "  " * depth
        author = item.get("author_username") or "unknown"
        created = item.get("created_at") or ""
        lines.append(f"{indent}- **@{author}** ({created})")
        lines.append(f"{indent}  - {item.get('text', '').replace(chr(10), ' ')}")
        media = item.get("media_urls", [])
        if media:
            lines.append(f"{indent}  - media: {', '.join(media)}")
    lines.append("")
    return "\n".join(lines)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Fetch an X/Twitter thread from a tweet URL."
    )
    parser.add_argument("tweet_url", help="Tweet URL like https://x.com/user/status/123")
    parser.add_argument(
        "--format",
        choices=["text", "json", "markdown"],
        default="text",
        help="Output format. Use json for Claude skill automation.",
    )
    parser.add_argument(
        "--out",
        help="Optional output file path. If omitted, prints to stdout.",
    )
    parser.add_argument(
        "--author-only",
        action="store_true",
        help="Keep only tweets from the same author as the requested tweet.",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="Silence progress logs (best for skill usage).",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Legacy alias for --format json.",
    )
    return parser.parse_args()


def write_output(content: str, output_path: str | None):
    if output_path:
        with open(output_path, "w", encoding="utf-8") as f:
            f.write(content)
    else:
        print(content)


def main():
    args = parse_args()
    output_format = "json" if args.json else args.format

    bearer_token = os.environ.get("BEARER_TOKEN") or os.environ.get("TWITTER_BEARER_TOKEN")
    if bearer_token and "%" in bearer_token:
        # Some tokens get pasted URL-encoded (e.g. %2B, %3D).
        bearer_token = unquote(bearer_token)

    if not bearer_token:
        print("Error: BEARER_TOKEN (or TWITTER_BEARER_TOKEN) environment variable not set.")
        print("Get one at: https://developer.twitter.com/en/portal/dashboard")
        sys.exit(1)

    try:
        tweet_id = extract_tweet_id(args.tweet_url)
        if not args.quiet:
            print(f"Fetching tweet ID: {tweet_id} ...")
        single_tweet = fetch_tweet(tweet_id, bearer_token)
        root = single_tweet.get("data", {})
        conversation_id = root.get("conversation_id") or root.get("id")
        if not args.quiet:
            print(f"Fetching thread conversation ID: {conversation_id} ...")
        thread_data = fetch_conversation(conversation_id, bearer_token)

        # Ensure the root tweet is present in final output.
        tweet_ids = {tweet.get("id") for tweet in thread_data.get("data", [])}
        if root and root.get("id") not in tweet_ids:
            thread_data.setdefault("data", []).append(root)
            includes = thread_data.setdefault("includes", {})
            includes.setdefault("users", [])
            includes.setdefault("media", [])
            for user in single_tweet.get("includes", {}).get("users", []):
                if user not in includes["users"]:
                    includes["users"].append(user)
            for media in single_tweet.get("includes", {}).get("media", []):
                if media not in includes["media"]:
                    includes["media"].append(media)

        thread_json = normalize_thread(thread_data, conversation_id, tweet_id)
        if args.author_only:
            author_id = root.get("author_id")
            thread_json["tweets"] = [
                tweet for tweet in thread_json["tweets"] if tweet.get("author_id") == author_id
            ]
            thread_json["meta"]["tweet_count"] = len(thread_json["tweets"])
            thread_json["meta"]["author_only"] = True

        if output_format == "json":
            output = json.dumps(thread_json, indent=2)
        elif output_format == "markdown":
            output = render_markdown(thread_json)
        else:
            output = format_thread(thread_data)
        write_output(output, args.out)

    except (ValueError, PermissionError, RuntimeError) as e:
        print(f"Error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()