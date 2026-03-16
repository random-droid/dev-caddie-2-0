# Scripts Reference

Runnable scripts in `scripts/`. Run from the project root.

---

## video_lecture_notes.py

Generate lecture notes from a YouTube video using Gemini 2.5 Flash. Downloads the video, uploads to GCS, calls Gemini for a study guide, extracts slide frames via ffmpeg, and stores the result in the `lecture_notes` BigQuery table.

**Basic usage:**

```bash
python scripts/video_lecture_notes.py "https://www.youtube.com/watch?v=VIDEO_ID" \
  --project YOUR_PROJECT_ID
```

**Recommended for long videos (2h+):**

```bash
python scripts/video_lecture_notes.py "https://www.youtube.com/watch?v=VIDEO_ID" \
  --project YOUR_PROJECT_ID \
  --skip-validation
```

`--skip-validation` skips the per-frame Gemini vision check that filters out non-slide frames (talking head, empty space). For content-dense videos like coding tutorials, this is fine and saves significant time and cost.

**All options:**

| Flag | Description |
|---|---|
| `--project` | GCP project ID for Storage and BigQuery (required) |
| `--genai-project` | Separate GCP project for Gemini calls (defaults to `--project`) |
| `--location` | GCP region (default: `us-central1`) |
| `--mock` | Simulate Gemini response without calling the API |
| `--force` | Regenerate even if the video was already processed |
| `--local-file PATH` | Use a local video file instead of downloading from YouTube |
| `--skip-validation` | Skip Gemini vision validation of slide frames (faster, lower cost) |
| `--clear-cache` | Delete the raw Gemini response cache for this URL and exit |
| `--sa-key PATH` | Path to a service account JSON key file |

**Notes:**

- Gemini's raw response is cached in GCS (`raw_cache/<article_id>_raw.json`). If processing fails after the Gemini call, re-running will skip the expensive call and use the cache.
- Use `--force` to re-run Gemini (e.g. after a prompt change). This clears the cache first.
- Use `--clear-cache` to wipe only the cache without regenerating.
- Cost is roughly $0.30–$1.00+ for a 2-hour video depending on token count.

---

## delete_lecture.py

Delete a lecture and all associated GCS assets (slide images, raw Gemini cache) by article_id.

**Usage:**

```bash
GOOGLE_APPLICATION_CREDENTIALS=/path/to/key.json python scripts/delete_lecture.py ARTICLE_ID \
  --project YOUR_PROJECT_ID
```

**Options:**

| Flag | Description |
|---|---|
| `--project` | GCP project ID (required) |
| `--bucket` | GCS bucket name (default: `content-intelligence-media-{project}`) |
| `--dry-run` | Show what would be deleted without actually deleting |

**Notes:**
- Deletes the BigQuery row in `lecture_notes`, all slide images in GCS, and the raw Gemini cache file.
- Use `--dry-run` first to confirm what will be removed.
- Credentials: set `GOOGLE_APPLICATION_CREDENTIALS` or use `gcloud auth application-default login`.

---

## backfill_embeddings.py

Generate `header_embedding`, `summary_embedding`, and `article_chunks` for articles already in BigQuery that are missing embeddings.

```bash
python scripts/backfill_embeddings.py --project YOUR_PROJECT_ID

# Dry run (count only, no writes)
python scripts/backfill_embeddings.py --project YOUR_PROJECT_ID --dry-run

# Re-embed all articles (not just missing)
python scripts/backfill_embeddings.py --project YOUR_PROJECT_ID --force
```

Default: only processes articles where `embeddings_updated_at IS NULL`.

---

## vacation.sh

Manage cost-saving modes when away. Controls the Airflow VM and Cloud Run service.

```bash
# First time only
chmod +x scripts/vacation.sh
```

**Commands:**

```bash
# Check what's running
./scripts/vacation.sh status

# Full shutdown (VM stopped, Cloud Run scaled to 0) — ~$0.50/day
./scripts/vacation.sh enable 14

# Maintenance mode (VM stopped, Cloud Run stays up but AI disabled) — ~$0.60/day
# Portfolio still visible, AI features paused
./scripts/vacation.sh maintenance 7

# Resume normal operation
./scripts/vacation.sh disable

# See cost breakdown
./scripts/vacation.sh cost-estimate
```

**When to use which:**

| Duration | Mode | Cost |
|---|---|---|
| 1–3 days | Keep running | ~$1.16/day |
| 4–7 days | `maintenance` | ~$0.60/day |
| 8+ days | `enable` (full shutdown) | ~$0.50/day |

**Note:** Edit `PROJECT_ID`, `VM_NAME`, `SERVICE_NAME`, and `REGION` at the top of `scripts/vacation.sh` to match your deployment before running.

---

## OPML Feed Management

### load_feeds_from_opml.py

Sync an OPML file into the `feeds_metadata` BigQuery table. Uses MERGE so existing feeds are updated and new ones are inserted without duplicates.

```bash
python scripts/load_feeds_from_opml.py data/feeds.opml YOUR_PROJECT_ID
```

### export_bq_feeds_to_opml.py

Export the current `feeds_metadata` table from BigQuery back to an OPML file. Useful for backup or importing into a feed reader.

```bash
python scripts/export_bq_feeds_to_opml.py YOUR_PROJECT_ID

# Custom output path
python scripts/export_bq_feeds_to_opml.py YOUR_PROJECT_ID data/feeds_export.opml
```

Requires the `bq` CLI to be installed and authenticated (`gcloud auth login`).

### merge_opml.py

Merge two OPML files into one, deduplicating by `xmlUrl`. External feeds are used as the base; local-only feeds are added on top. Category names are normalized via the `CATEGORY_MAPPING` dict at the top of the script.

```bash
# Defaults: merges data/feeds.opml + external path hardcoded in script → writes back to data/feeds.opml
python scripts/merge_opml.py
```

Typical workflow when pulling in a new external feed list:
1. Run `merge_opml.py` to produce an updated `data/feeds.opml`
2. Run `load_feeds_from_opml.py` to push it to BigQuery
