# Dev Caddie 2.0

> Turns video into a knowledge graph for a real-time voice tutor. Stop passive watching; start conversational mastery grounded in your research feed.

**Live Demo:** [dev-caddie-hackathon-blz5bvu6kq-uc.a.run.app](https://dev-caddie-hackathon-blz5bvu6kq-uc.a.run.app)

**Hackathon:** [Gemini Live Agent Challenge](https://ai.google.dev/competition/gemini-live-agent-challenge) — "Sovereign Learning Agent"

---

## Two Pillars

### 1. Lecture Caddie — Real-Time Voice Tutor

A Gemini Live voice agent that explains lecture content as you study — grounded in the lecture transcript and your personal engineering feed. Pause the video; Caddie explains exactly what just happened.

### 2. Smart Feed — AI-Curated Engineering News

~190 RSS and engineering feeds ranked daily by Gemini 2.5 Flash, with HackerNews and Lobsters community engagement as a second signal. The crowd acts as a quality filter before the AI ever sees an article.

---

## Lecture Caddie — How It Works

### 4-Pass Gemini 2.5 Flash Pipeline

`video_lecture_notes.py` ingests a YouTube video through four sequential Gemini passes:

| Pass | Input | Output |
|------|-------|--------|
| 1. Transcript + Structure | Raw video (via GCS) | Section outline, key timestamps |
| 2. Knowledge Graph | Transcript + outline | Concepts, definitions, relationships |
| 3. Cornell Notes | Sections + concepts | Takeaway / Timestamp / Explanation table |
| 4. Slide Validation | Frame snapshots (ffmpeg) | Filters non-slide frames; links `[SLIDE: MM:SS]` anchors |

Raw Gemini responses are cached in GCS (`raw_cache/<article_id>_raw.json`). Reprocessing after a failure skips the expensive API call.

### Voice Agent

The live tutor runs on a GCE VM sidecar: **Pipecat + Daily WebRTC + Gemini Live 2.5 Flash** (Vertex AI). The pipeline state machine:

| Bot State | Gate | Trigger |
|-----------|------|---------|
| Standby | CLOSED | video-playing |
| Pending (amber pulse) | — | video-paused sent, awaiting backend confirm |
| Active / Listening | OPEN | `gate-status: open` received |
| Speaking | OPEN | Gemini generating audio |
| Ghost Resume | — | bot-graceful-disconnect → user re-pauses |

### Key Features

| Feature | Technical Implementation | Value Proposition |
|---------|--------------------------|-------------------|
| **Hard Anchoring** | YouTube `currentTime` synced into agent system prompt on every pause | Agent speaks to exactly what is on screen, not the general topic |
| **Ghost Resume** | Continuity packets `{learned, struggling, open_threads}` written to Redis (24h TTL, scoped by `article_id + client_id`) | Re-connect mid-lecture; the agent remembers what you covered |
| **Deterministic Context Injection** | `InputTextRawFrame` injects top-3 relevant feed articles per lecture section | Cross-source reasoning: professor's words vs. live industry discourse |
| **Deterministic Sync** | Backend Oracle + Gate-Mirroring (`gate-status` messages) | Zero ghost triggers or audio overlaps |
| **Grounded Response** | Sequential Tool-Dependency Protocol (`CRITICAL PROTOCOL` in system instruction) | AI never guesses; 100% lecture accuracy |

### Dynamic Context Synthesis — On-Demand Contextual Bridge

When the user pauses, Caddie pre-computes semantic bridges to high-signal technical discourse (HN, Lobsters) and surfaces them as clickable cards in the sidebar. The user decides when — and if — that research enters the conversation.

Clicking a card injects the article title and `ai_reasoning` as an `InputTextRawFrame`:

```python
inject_text = f'I found this related article: "{title}". {reasoning}. How does this connect to what we just covered?'
await task_ref.queue_frame(TranscriptionFrame(text=inject_text, user_id="user", timestamp=time.time()))
```

**Why `InputTextRawFrame` and not a context update:**

- **Zero hallucination** — Gemini receives the `ai_reasoning` verbatim, not a vague title. It reasons from the actual text, not its training weights.
- **Immediate reasoning** — Gemini Live is optimized for "user" turns. The injection triggers synthesis instantly, at the current lecture timestamp.
- **Ghost Resume continuity** — the injected article becomes part of the conversation history saved to Redis. On reconnect, the continuity packet already knows the student read it.
- **User agency** — the graph shows concepts, the sidebar shows articles, but the student controls what enters Gemini's active context. No AI overload.

The result: Gemini can compare what the professor said at `[12:45]` with the cutting-edge implementation in an injected HN article — cross-source reasoning grounded in both the lecture and live industry discourse.

### Cost Control & Fairness

Lecture Caddie sessions run on Gemini Live native audio (PayGo tier — billing account linked). Cost protection is enforced at the API layer via two mechanisms backed by **Firestore** for distributed state across Cloud Run instances:

| Layer | Mechanism | Limit |
|---|---|---|
| Burst protection | `slowapi` rate limiter | 5 session starts / minute per IP |
| Per-user fairness | Firestore per-IP counter | 10 sessions / day per IP |
| Global safety net | Firestore daily budget guard | $2 / day (≈ 10–20 sessions) |

Each session is recorded at **$0.15** estimated cost (Gemini Live audio ~$0.35/min × avg 5 min). `get_client_ip()` reads `X-Forwarded-For` correctly behind the Cloud Run proxy so per-IP limits apply to real IPs, not the load balancer.

---

## Smart Feed — How It Works

### Dual-Scoring (Community Signal as Rate Limiter)

HackerNews and Lobsters engagement acts as a **volume cap and quality filter** before Gemini ever sees an article. Low-engagement articles are scored conservatively; viral content overrides the AI weight.

```
         Community Score (Popularity)
              ▲
          100 │             ┌──────────┐
              │             │  GOLD!   │  ← Relevant + Community-Validated
              │             │ Top-Right│
           70 │─────────────┴──────────┤ ← Viral Override threshold
              │  Water       │         │
              │  Cooler     │ Risky   │
              │  (popular)   │(unproven)│
            0 │──────────────┴─────────────→
              0        50        100
                   AI Relevance Score
```

**Scoring formula (from `community_scorer.py`):**

```python
# HN weighted 70%, Lobsters 20%, Comments 10%
hn_score = min(hn_points / 500.0 * 70, 70)
lobsters_score = min(lobsters_points / 100.0 * 20, 20)
comment_score = min(total_comments / 100.0 * 10, 10)

# Confidence-based weighting
weights = {'high': (0.5, 0.5), 'medium': (0.7, 0.3), 'low': (0.9, 0.1)}

# Junk Floor: AI < 25 → community can't save junk content
if ai_relevance < 25:
    final_score = ai_relevance

# Viral Override: community > 70 AND ai >= 25 → favor social signal
if community_score >= 70 and ai_relevance >= 25:
    ai_weight, community_weight = 0.3, 0.7
```

**Model:** `gemini-2.5-flash` with structured JSON output + Pydantic validation.

### StruQ Chat Assistant

Natural language queries are routed through a structured intent extraction step before hitting BigQuery — eliminating SQL injection risk entirely.

```python
class SearchIntent(BaseModel):
    intent_type: Literal["search", "recommendation", "explanation"]
    topics: List[str] = []
    time_range_days: int = 30
    min_score: int = 60
    content_type: Optional[str] = None
```

User text → Gemini → `SearchIntent` → parameterized BQ SQL. Gemini never generates SQL; it only extracts typed fields. Vector search embeds `intent.topics`, not the raw query text, to avoid corrupting the embedding space.

### Crawl-Once, Embed-Once

The daily DAG crawls article URLs once and writes full text to `article_content_cache`. Downstream tasks (embedding, briefing) read from the cache via LEFT JOIN — no re-fetching, no re-billing.

---

## Architecture

```
YouTube / RSS Feeds (~190 feeds via OPML)
         │
         ▼
Airflow DAG (daily @ 13:00 UTC) — Cloud Composer
         │
         ├─ Fetch & Dedupe (SHA-256 URL hashes)
         ├─ Crawl → article_content_cache (BigQuery)
         ├─ AI Scoring (Gemini 2.5 Flash → structured JSON)
         ├─ Community Enrichment (HN Algolia + Lobste.rs APIs)
         ├─ Final Score = weighted(AI, Community) + viral override
         ├─ Embed (text-embedding-004 → header_embedding, article_chunks)
         └─ Briefing script generation
                  │
                  ▼
         BigQuery
         ├─ articles_scored
         ├─ article_chunks (concept embeddings, 500-word, max 5/article)
         ├─ article_content_cache (90-day TTL)
         ├─ lecture_notes
         └─ daily_briefings
                  │
                  ▼
         Cloud Run (FastAPI)
         ├─ static/index.html  — Smart Feed UI
         ├─ static/lecture.html — Lecture Caddie UI
         ├─ /api/assistant — StruQ chat (NL → BQ)
         ├─ /api/articles, /api/trending
         ├─ /api/lecture/start-session — Firestore BudgetGuard
         └─ /api/lecture/context — tool endpoint for Gemini Live
                  │
         ┌────────┴────────┐
         ▼                 ▼
GCE VM Sidecar          Redis (airflow-vm)
Pipecat Pipeline        Continuity Packets
├─ UserAudioGate        24h TTL per (article_id, client_id)
├─ Gemini Live 2.5 Flash
├─ get_lecture_context() tool
└─ UiSyncProcessor
   ├─ gate-status: open/closed
   ├─ bot-speaking: true/false
   ├─ spike2-articles (Related Reading)
   └─ bot-graceful-disconnect (Ghost Resume trigger)
```

---

## Tech Stack

| Component | Technology |
|-----------|------------|
| Orchestration | Apache Airflow 2.8 on Cloud Composer (GCE) |
| Backend | FastAPI on Cloud Run |
| AI Scoring & Pipeline | Gemini 2.5 Flash (Vertex AI) |
| Voice Agent | Gemini Live 2.5 Flash + Pipecat + Daily WebRTC (GCE VM sidecar) |
| Embeddings | text-embedding-004 (Vertex AI) |
| Storage | BigQuery, Firestore (rate limits), GCS (media + raw cache), Redis (continuity) |
| Frontend | Vanilla HTML/CSS/JS (`index.html`, `lecture.html`) |
| Rate Limiting | Firestore BudgetGuard + `slowapi` |
| Validation | Pydantic schemas |
| Observability | Cloud Monitoring + Cloud Logging |

---

## Cost

| Component | Monthly Cost |
|-----------|-------------|
| Gemini 2.5 Flash (scoring, pipeline, chat) | ~$1 |
| Gemini Live audio (Vertex AI free tier: 15h/month) | ~$0 |
| Cloud Run | ~$0 (free tier) |
| BigQuery + Firestore + GCS | ~$0 (free tier) |
| Compute Engine (Airflow VM + sidecar VM) | ~$20 |
| **Total** | **~$23–30/month** |

**Cost per article scored:** ~$0.0002
**Cost per voice session:** ~$0.15 estimated (Gemini Live PayGo, avg 5 min)
**Daily budget cap:** $2

---

## Scripts

All scripts live in `scripts/`. See [docs/SCRIPTS.md](docs/SCRIPTS.md) for full reference.

| Script | Purpose |
|--------|---------|
| `video_lecture_notes.py` | 4-pass lecture ingestion (YouTube → BigQuery + GCS) |
| `delete_lecture.py` | Delete a lecture and all GCS assets by article_id |
| `backfill_embeddings.py` | Embed articles missing `embeddings_updated_at` |
| `vacation.sh` | Cost management: full/maintenance/disable modes |
| `load_feeds_from_opml.py` | Sync OPML file → `feeds_metadata` BigQuery table |
| `export_bq_feeds_to_opml.py` | Export `feeds_metadata` → OPML file |
| `merge_opml.py` | Merge two OPML files, deduplicating by `xmlUrl` |

---

## Hackathon

**Gemini Live Agent Challenge** — submitted March 2026.

**Pitch:** Sovereign Learning Agent. The agent is grounded in two sources of truth the user owns: their curated engineering feed (190 sources, daily-ranked) and their lecture knowledge graph (4-pass Gemini pipeline). It does not hallucinate; every claim links to a lecture timestamp or a community-validated article. Ghost Resume means context survives tab closes and reconnects. The user's learning state is durable.

---

## License

MIT
