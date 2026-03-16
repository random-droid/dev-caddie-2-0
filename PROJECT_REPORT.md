# Dev Caddie 2.0 — Technical Report

> Turns video into a knowledge graph for a real-time voice tutor. Stop passive watching; start conversational mastery grounded in your research feed.

**Live Demo:** [dev-caddie-hackathon-blz5bvu6kq-uc.a.run.app](https://dev-caddie-hackathon-blz5bvu6kq-uc.a.run.app)
**Cost:** ~$23–30/month | **Feeds:** ~190 active | **Output:** 5–10 high-signal reads/day + voice tutor

---

## The Problem

Engineers face two compounding issues:

**Discovery latency.** 500+ articles per day across RSS feeds, HackerNews, and Lobsters. Manual curation takes hours. AI summarization alone has a fatal flaw — it cannot distinguish between a random tutorial and a battle-tested Netflix engineering post if both match your keyword interests:

```
Article A: "My Flink Tutorial"      → AI Score: 85 (matches interests!)
Article B: "Flink at Netflix Scale" → AI Score: 85 (also matches!)

Single-dimension AI treats these THE SAME.
But Article B has 5,000 HN upvotes and 300 comments.
```

**Deep-dive video.** High-quality engineering lectures (MIT OCW, Stanford, conference talks) are dense and long. Passive watching is inefficient. There is no interactive layer that grounds a question-and-answer session in the actual lecture content rather than in model training weights. Scrubbing a 90-minute recording to find "that one slide" is a solved problem that nobody has solved well.

---

## The Solution: Two-Pillar Sovereign Learning Agent

Dev Caddie 2.0 addresses both problems under a single framing: a **Sovereign Learning Agent** — an agent grounded in two sources of truth the user owns, not in general web knowledge.

**Pillar 1 — Smart Feed.** ~190 RSS and engineering feeds ranked daily by Gemini 2.5 Flash with HackerNews and Lobsters community engagement as a second signal. The crowd acts as a quality filter and volume cap before the AI touches an article.

**Pillar 2 — Lecture Caddie.** Ingests YouTube lectures through a 4-pass Gemini 2.5 Flash pipeline, builds a temporally-indexed knowledge graph, and grounds a real-time Gemini Live voice tutor in both the lecture and the user's ranked feed. Pause the video; the agent explains what just happened — from the lecture, not from training data.

---

## Key Innovations

### 1. Dual-Scoring (Community Signal as Infrastructure)

Community engagement data is not a tie-breaker or a display badge. It is used as a **volume cap and quality filter** before Gemini scores articles, and as an override mechanism when social signal dominates.

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

# Junk Floor: AI < 25 → community cannot save junk content
if ai_relevance < 25:
    final_score = ai_relevance

# Viral Override: community > 70 AND ai >= 25 → favor social signal
if community_score >= 70 and ai_relevance >= 25:
    ai_weight, community_weight = 0.3, 0.7
```

All scores are validated via Pydantic: `ai_relevance_score: int = Field(ge=0, le=100)`.

Articles can go viral days after initial scoring. A decay-based rescore schedule catches late bloomers without unbounded API cost:

| Article Age | Rescore Frequency |
|-------------|------------------|
| 0–48 hours | Every 16 hours |
| 2–7 days | Daily |
| 7–30 days | Weekly |
| 30+ days | Stop |

**Why this matters:** Community signal is infrastructure, not decoration. It eliminates derivative content naturally — a low-engagement tutorial about a well-covered topic simply never accumulates the HN points to compete with the original source. No semantic deduplication pass required at scale; the crowd already ran it.

---

### 2. 4-Pass Gemini 2.5 Flash Pipeline

`video_lecture_notes.py` ingests a YouTube video through four sequential Gemini passes, each building on the output of the previous:

| Pass | Input | Output |
|------|-------|--------|
| 1. Transcript + Structure | Raw video uploaded to GCS | Section outline, key timestamps, chapter markers |
| 2. Knowledge Graph | Transcript + section outline | Concepts, definitions, relationships, prerequisite links |
| 3. Cornell Notes | Sections + knowledge graph | Takeaway / Timestamp / Explanation table per section |
| 4. Slide Validation | Frame snapshots extracted by ffmpeg | Filters non-slide frames (talking head, blank screen); links `[SLIDE: MM:SS]` anchors to notes |

Raw Gemini responses are cached in GCS at `raw_cache/<article_id>_raw.json`. If processing fails after the Gemini call (e.g., a BigQuery write error), re-running skips the expensive API call and uses the cache. Use `--force` to intentionally re-run Gemini after a prompt change; this clears the cache first.

The pipeline output is stored in the `lecture_notes` BigQuery table and referenced by the voice agent at runtime.

**Why four passes and not one:** A single pass over a 90-minute video produces a summary. Four passes produce a temporally-indexed knowledge graph — a data structure the voice agent can query by concept, by timestamp, or by section. The distinction is the difference between a summary and a study tool.

---

### 3. Voice Agent: Hard Anchoring, Ghost Resume, Deterministic Context Injection

The voice tutor runs on a GCE VM sidecar using **Pipecat + Daily WebRTC + Gemini Live 2.5 Flash** (Vertex AI). Three mechanisms make it genuinely grounded rather than generic:

**Hard Anchoring.** YouTube `currentTime` is synced into the agent's system prompt on every pause event. The agent speaks to exactly what is on screen at the moment of the pause, not to the general topic of the video. Without this, Gemini Live would reason from training data about the topic; with it, the context window is pinned to the lecture's exact words at that timestamp.

**Ghost Resume.** When a session ends (tab close, network drop, explicit disconnect), the agent writes a continuity packet to Redis:

```json
{
  "learned": ["concept A", "concept B"],
  "struggling": ["concept C — asked twice, still uncertain"],
  "open_threads": ["user asked about X, we were mid-explanation"]
}
```

Keys are scoped by `(article_id, client_id)` with a 24-hour TTL. On reconnect, the packet is injected into the new session's system prompt. The agent resumes as if the conversation never dropped.

**Deterministic Context Injection.** When the user pauses, the backend pre-computes a vector search over `article_chunks` to find the top-3 feed articles semantically relevant to the current lecture section. These are surfaced as clickable cards in the sidebar. When the user clicks a card, the article title and `ai_reasoning` are injected via `InputTextRawFrame` — not as a context update, but as a user turn:

```python
inject_text = f'I found this related article: "{title}". {reasoning}. How does this connect to what we just covered?'
await task_ref.queue_frame(TranscriptionFrame(text=inject_text, user_id="user", timestamp=time.time()))
```

This pattern has three properties that a context update does not: Gemini receives the full text verbatim so it reasons from content rather than training weights; the injection triggers immediate synthesis because Gemini Live is optimized for user turns; and the injected article enters the conversation history written to Redis, so Ghost Resume knows the student already read it.

**State machine:**

| Bot State | Gate | Trigger |
|-----------|------|---------|
| Standby | CLOSED | video-playing |
| Pending (amber pulse) | — | video-paused sent, awaiting backend confirm |
| Active / Listening | OPEN | `gate-status: open` received |
| Speaking | OPEN | Gemini generating audio |
| Ghost Resume | — | bot-graceful-disconnect → user re-pauses |

Gate state is managed by the `UserAudioGate` processor (drops audio while video is playing) and mirrored to the frontend via `gate-status` transport messages. This eliminates ghost triggers — cases where background audio leaks into the model during non-interactive segments.

---

### 4. StruQ Pattern (SQL Injection-Safe Natural Language → BigQuery)

The feed chat assistant routes all natural language queries through a structured intent extraction step before constructing SQL. Gemini never generates SQL from user text; it only extracts typed fields.

**The problem:**
```
User: "Show me articles; DROP TABLE articles_scored;--"
Naive NL→SQL: SELECT * FROM articles WHERE title LIKE '%DROP TABLE...%'
```

**The StruQ solution:**
```
User input → Gemini extracts SearchIntent → Map to parameterized BigQuery SQL
```

```python
class SearchIntent(BaseModel):
    intent_type: Literal["search", "recommendation", "explanation"]
    topics: List[str] = []
    time_range_days: int = 30
    min_score: int = 60
    content_type: Optional[str] = None
```

**Critical implementation detail:** The embedding step embeds `intent.topics`, not the raw `query_text`. Raw user text embedded directly corrupts the vector space — the embedding ends up representing the conversational framing of the question rather than the underlying concepts. The fix:

```python
embed_text = " ".join(intent.topics) if intent.topics else query_text
```

Vector search runs `VECTOR_SEARCH` on `header_embedding`, `top_k=50`, then filters by `scored_at` recency and `final_score` threshold.

---

### 5. Rate Limiting: Firestore BudgetGuard + X-Forwarded-For Fix

Cost control is enforced at the API layer via Firestore-backed counters that survive Cloud Run instance recycling and scale horizontally across instances.

**The X-Forwarded-For problem.** Cloud Run sits behind a Google load balancer. Without explicit header parsing, `request.client.host` returns the load balancer's internal IP — every user appears to be the same IP. Per-IP rate limiting becomes per-platform rate limiting: the first user to hit the daily cap blocks everyone else.

**The fix** (`get_client_ip()` in `main.py`):

```python
forwarded_for = request.headers.get("X-Forwarded-For")
if forwarded_for:
    return forwarded_for.split(",")[0].strip()
return request.client.host
```

The first IP in `X-Forwarded-For` is the original client IP set by Google's load balancer before any user-controlled headers are appended. This makes per-IP limits apply to real client IPs.

**Three-layer cost defense for Lecture Caddie sessions:**

| Layer | Mechanism | Limit |
|---|---|---|
| Burst protection | `slowapi` rate limiter | 5 session starts / minute per IP |
| Per-user fairness | Firestore per-IP counter | 10 sessions / day per IP |
| Global safety net | Firestore daily budget guard | $2 / day (≈ 10–20 sessions) |

Community signal on the Smart Feed side acts as a **natural rate limiter** at the data layer: low-engagement articles are filtered out before Gemini scoring, so the daily Gemini budget is concentrated on articles that already passed a crowdsourced quality bar.

---

## Security: 5-Layer Defense-in-Depth

| Layer | Implementation | Purpose |
|-------|----------------|---------|
| 1. Input Validation | 20+ compiled regex patterns | Block injection attempts |
| 2. Secure Prompt Construction | XML delimiters, explicit rules | Isolate user input from system instructions |
| 3. Structured Output | JSON schema + Pydantic | Constrain LLM responses to typed fields |
| 4. Output Validation | Prompt leak detection, PII patterns | Catch model compromise attempts |
| 5. Rate Limiting | Firestore BudgetGuard + `slowapi` | Protect wallet from abuse |

---

## Cost Breakdown

| Component | Monthly Cost |
|-----------|-------------|
| Gemini 2.5 Flash (scoring, 4-pass pipeline, chat) | ~$1 |
| Gemini Live audio (Vertex AI free tier: 15h/month) | ~$0 |
| Cloud Run | ~$0 (free tier) |
| BigQuery + Firestore + GCS | ~$0 (free tier) |
| Compute Engine (Airflow VM + sidecar VM) | ~$20 |
| **Total** | **~$23–30/month** |

**Cost per article scored:** ~$0.0002
**Cost per voice session:** ~$0.15 estimated (Gemini Live PayGo, avg 5 min)
**Daily budget cap:** $2

**Voice briefings via Vertex AI free tier:**

| Vertex AI Free Tier | Monthly Allowance |
|---------------------|-------------------|
| Gemini Live Audio Input | 15 hours/month |
| Gemini Live Audio Output | 15 hours/month |
| Gemini 2.5 Flash (text) | 1M tokens/month |

A daily user running 5-minute sessions consumes ~100 minutes/month — under 12% of the free audio tier. The marquee feature costs $0 for typical usage. The ~$20/month is infrastructure (Compute Engine VMs for Airflow orchestration and Pipecat real-time audio delivery), not AI inference.

| Cost Optimization | Savings |
|------------------|---------|
| Hash-based URL deduplication | ~30% fewer Gemini calls |
| HN RSS pre-population | ~30% fewer HN Algolia API calls |
| Batched scoring (10 articles/request) | ~80% fewer Gemini API round trips |
| Decay-based rescoring | Bounded community rescore cost |
| GCS raw cache for Gemini responses | Zero re-billing on reprocessing |
| Crawl-once pattern (`article_content_cache`) | No re-fetching in embed or briefing steps |

---

## What We Learned

**Orchestration beats prompting.** The 4-pass pipeline produces structurally richer output than any single prompt could, not because each pass uses a better prompt, but because each pass operates on the cleaned, typed output of the previous one. The knowledge graph in Pass 2 is better because the structure from Pass 1 constrains it. Prompting is local; orchestration is architectural.

**Community signal is infrastructure, not decoration.** Using HN and Lobsters as a volume cap before Gemini scoring — rather than as a post-hoc display badge — changes the economics. The crowd pre-filters ~70% of articles, so Gemini's daily budget is spent on content that already cleared a quality bar set by practitioners. The junk floor and viral override are not heuristics; they are load-shedding logic.

**Contextual durability is the hard problem in voice agents.** Latency and voice quality are solved by the platform (Daily + Pipecat handle the WebRTC and audio pipeline). The unsolved problem is whether the agent knows what the user already understands. Ghost Resume — writing structured continuity packets to Redis at session end and injecting them at reconnect — is a six-line solution to a problem that otherwise requires the user to re-explain their context every session.

---

## Future Roadmap

**Topological memory.** Replace flat continuity packets with a graph structure in Redis. Concepts the user has encountered multiple times, concepts they have struggled with, and concepts introduced in one lecture that appear in another should be connected — not just listed. A graph lets the agent surface prerequisite gaps rather than just recapping history.

**Multi-agent personas.** A single Gemini Live session handles explanation, Q&A, and article injection. These are different interaction modes with different optimal system instructions. A routing layer that switches the active persona (explainer, Socratic questioner, research synthesizer) based on conversational state would produce more focused responses.

**ArXiv with citation velocity.** The Smart Feed currently indexes engineering blogs and community aggregators. Academic preprints (ArXiv) represent an earlier signal — a paper cited by 50 HN posts was influential before those posts existed. Adding citation velocity as a feature alongside community engagement would push the discovery window earlier.

**Semantic deduplication.** The current community signal naturally filters derivative content because low-engagement articles do not accumulate HN points. An explicit embedding-based similarity check (`VECTOR_SEARCH` over the last 30 days, penalty for cosine similarity > 0.85 to a higher-scored article) would catch derivative content from sources that do generate community engagement by riding a topic wave.

---

*Last updated: 2026-03-15*
