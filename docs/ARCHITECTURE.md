# Dev Caddie - Architecture Overview

## System Overview
Dev Caddie is a distributed hybrid system designed for low-latency voice briefings and high-signal content curation.

```
Browser UI
  ↕ Cloud Run (FastAPI + UI)
      ↕ (Internal service call)
        Sidecar Runtime (Pipecat + Daily + Gemini Live)
  ↕
Airflow (DAG)
  ↕
BigQuery (scored articles + daily briefing scripts)
```

## Core Responsibilities

- **Cloud Run**: UI + API gateway. Creates Daily rooms, starts/stops sidecar, serves briefing scripts and chat results.
- **Sidecar Runtime**: Pipecat + Daily WebRTC + Gemini Live audio. Handles real-time audio and barge‑in gating.
- **Airflow**: RSS ingestion, scoring, ranking, and daily briefing script generation.
- **BigQuery**: Persistent storage for scored articles and daily scripts.

## Data Pipeline (Airflow + BigQuery)

1. Fetch active feeds from metadata.
2. Pull RSS articles.
3. Deduplicate by normalized URL hash.
4. Score with Gemini + community signals.
5. Clean article text (Trafilatura strips boilerplate; regex normalizes encoding).
6. Generate multi-vector embeddings via `text-embedding-004`:
   - `header_embedding` — title + first paragraph: high-level intent and topic categorization
   - `summary_embedding` — AI-generated abstract: captures "why this matters"
   - `concept_embeddings` — body split into 500-token semantic chunks: finds specific technical details
7. Store into `articles_scored` (with `primary_tags`, `secondary_tags`, multi-vector embeddings).
8. Generate daily briefing script into `daily_briefings`.

**Text Embedding Noise: High-Signal Ingestion**

A single embedding per article drifts for long pieces covering multiple topics. Multi-vector storage solves four specific noise problems:

| Noise Type | Problem | Fix |
|---|---|---|
| Boilerplate | Nav menus, tracking pixels pulled into vector | Trafilatura strips to content body before embedding |
| Semantic dilution | Fluff + ad copy weakens technical signal | Contextual chunking — title+summary prepended to anchor each chunk |
| Structural noise | Mojibake, PDF hyphens, excessive whitespace | Regex cleaning + encoding normalization before embedding |
| Intent overlap | Article on 3 topics sits in the "middle" of all three, matching poorly for each | Three vector types: header (intent), summary (why it matters), concept chunks (technical detail) |

RSS articles already arrive with boilerplate partially stripped, but multi-vector is the most impactful change for 2nd/3rd order precision in the star schema.

**Article Embedding Backfill Plan**

Existing `articles_scored` rows predate the embedding columns. Backfilling all history is expensive and low-value — articles older than 30 days are unlikely to surface in lecture cross-pollination.

| Phase | Scope | Mechanism | Cost |
|---|---|---|---|
| Forward (day 0+) | All new articles | Embedded inline in daily Airflow DAG | ~$0 (free tier) |
| Hot backfill | Last 30 days | One-off Airflow task, batched 50/request | Low — ~days of data |
| Cold archive | 30+ days | Skip — decay-based rescoring already stops at 30 days | $0 |

**Cascade to keep costs bounded:** only articles that pass the community signal pre-filter (score > threshold) get embedded. Articles that won't surface in RAG don't need embeddings.

## Scoring (Triple Signal)

Final score blends AI relevance, community signals, and feed convergence.

```
weights = get_adaptive_weights(content_age, community_signal_strength)
```

**Feed Convergence Boost**
When 3+ RSS feeds independently publish the same article, that convergence is treated as a signal — not penalized as a saturated topic. Each feed beyond 2 adds +3 to the final score (capped at +10). `feed_ids` is the lineage field tracking this.

**Novelty Scoring (corrected)**
The AI scorer penalizes *derivative content* (same argument, reworded) but not *topic convergence* (multiple original takes on the same hot topic). An unknown author with original data or a production war story scores HIGH regardless of topic saturation.

**Convergence is dynamic**
`feed_ids` grows as more feeds pick up an article over time. The rescore service re-reads `feed_ids` on each cycle and reapplies the convergence boost, so articles that spread across the ecosystem get rescored upward automatically.

## Smart Feed Chat Assistant (StruQ)

Gemini extracts **structured intent** only (no SQL generation), which maps to parameterized queries. This prevents prompt injection while enabling natural language search.

## Morning Briefing (Deterministic + Q&A)

- **Deterministic script**: greeting + 5 summaries + closing.
- **Gemini Live** reads verbatim to avoid hallucinations.
- **Barge‑in gate** controls interruptions (OFF during narration, ON during Q&A).

## Observability

- **Briefing metrics**: TTFB, tokens, turns, interruptions.
- **Scoring metrics**: batch stats and coverage.
- **Repo observability**: cost + latency dashboards.

## Lecture Companion (Planned — Gemini Live Agent Challenge)

A **dual-mode, knowledge-aware companion** for watching technical lectures. Distinct from the morning briefing in lifecycle: dormant during playback (visual-only), fully conversational during pause (Gemini Live audio).

**Two modes, one session:**
| Player State | Caddie Mode | Output |
|---|---|---|
| Playing | Visual indexing — silent | 1-3 star graph cards in sidebar |
| Paused | Conversational — Gemini Live active | Audio Q&A + card updates |

### Why Hybrid RAG: The Static-Dynamic Paradox

A technical research assistant needs to be simultaneously an expert on a specific video (the "Anchor") and the shifting world outside it (the "Smart Feed"). A single RAG architecture cannot satisfy both. Hybrid RAG was the engineering response to four specific bottlenecks.

**1. Latency vs. Context**
Treating the video as just another vector in a giant database loses the Temporal Graph — the agent wouldn't know that a code block at minute 40 is a direct evolution of a diagram at minute 5. Static pre-ingested graph gives the agent an immediate map of the lecture's internal logic. No search — it already owns the context.

**2. The Freshness Gap**
A RAG system built only on the video is trapped in the past. A 2024 video gives 2024 advice. Dynamic live cross-pollination via daily BigQuery RSS articles upgrades a 2024 concept with a 2026 article. The video becomes a live entry point into current research, not a static archive.

**3. Ball-of-Wool Inference**
Unrestricted graph linking becomes a tangled mess — the Obsidian Effect. The Star Schema enforces a controlled boundary. The hub (current segment) only reaches out to spikes (RSS articles) on 2nd/3rd order semantic match. High-signal, low-noise by design.

**4. Operational Sovereignty**
A managed cloud RAG service makes Application-Layer Gating impossible. Self-hosted sidecar owns the orchestration — the inference engine only opens when the user pauses. Zero token bleed during 60 minutes of passive watching. This is the only architecture that produces the Silent Caddie experience.

> Hybrid RAG was the only way to build a system that is contextually deep (Video Graph), temporally fresh (RSS Trove), and architecturally efficient (Stateful Sidecar).

### Architecture

```
Pre-Ingestion (once, permanent):
  YouTube URL → transcript (youtube-transcript-api)
             → Gemini Flash segments by topic boundary
             → Star Schema concept expansion per segment (3 orders max)
             → embedding (text-embedding-004)
             → stored in video_segments (BQ)

RSS Article Index (daily, via Airflow):
  articles_scored → primary_tags + secondary_tags per article
                 → ready for live cross-pollination at playback time
                 → no pre-linking to videos — tags are the index

At Playback — Playing (zero AI tokens):
  YouTube timestamp → BQ segment lookup (start_sec/end_sec window)
                   → segment row: concepts JSON, primary_tags, embedding (pre-ingested)
                   → Hybrid RAG against today's articles_scored (daily-refreshed):
                       • Tag match:        segment.primary_tags ∩ article.tags   (precision)
                       • Embedding match:  cosine(segment.embedding, article.embedding) (recall)
                   → top 1-3 articles per segment → cards rendered in sidebar

At Playback — Paused (Gemini Live opens):
  onPause event   → Gemini Live session starts (pipe opens)
                  → context injected (segment-scoped):
                       • concepts JSON for this segment (pre-ingested, stable)
                       • matched articles for this segment (live, from today's Airflow run)
                  → user speaks → Gemini answers using both
                  → onPlay event → Gemini Live session closes (pipe shuts, zero idle tokens)
```

### Star Schema Inference Model (Controlled, not Graph)

Dev Caddie avoids "Graph Fatigue" — the Obsidian problem where everything connects to everything and produces a useless spiderweb. Instead it uses a **strict 3rd-order star schema** centered on the current video frame, with all relationships single-hop from one hub. No chain reactions, no noise.

```
                    ▲ Spike 1: Temporal Hierarchy
                    │ (self-referencing parent — prerequisite segment)
                    │
Spike 2 ──── [Current Frame / Hub] ──── Spike 2: RSS cross-pollination
(live vector  (timestamp center)              (live BQ articles via
 search)                                       embedding similarity)
                    │
                    ▼ Spike 3: Project context
                    (user's active tags/topics as final filter)
```

**The Hub: Visual Index Table**

| Field | Purpose |
|---|---|
| `video_id` | Video identity |
| `timestamp_seconds` | Position in lecture |
| `frame_summary` | What is happening now |
| `visual_embedding` | Semantic fingerprint for vector search |

**Spike 1 — Temporal Hierarchy (Up/Down)**

Self-referencing parent ID — not an infinite graph, just one level up or down. Each segment links to a parent concept or prerequisite segment, letting the agent say: *"This code block depends on the definition at 05:00."*

**Spike 2 — Semantic Cross-Pollination (Side-to-Side)**

Articles stay in `articles_scored`. The link is generated live:
`cosine(segment.visual_embedding, article.article_embedding)`

No pre-linking between videos and articles — tags and embeddings are the index. Capped at 2nd / 3rd order results. Won't suggest "Browser History" just because WebRTC runs in a browser — only direct technical lineage.

**Spike 3 — Project Context (Grounding)**

Tags or keywords from the user's active project metadata (GitHub, active topics) applied as a final filter on BQ results. Bridges theory to what the user is *building*, not just what they are *watching*.

| Order | Scope | Example |
|---|---|---|
| 1st | Direct keyword match | Lambda Architecture → Lambda article |
| 2nd | Contextual parent | Lambda → Kappa/Delta patterns (competitors) |
| 3rd | Project inference | Watching eBPF + building Dev Caddie → real-time orchestration article |

**4th order and beyond is discarded.** "History of the person who invented Lambda" is noise.

**Implementation: BigQuery as a Virtual Graph (no GraphDB needed)**

| Mechanism | Role |
|---|---|
| `primary_tags` / `secondary_tags` in segment rows | Tag-based precision matching |
| `VECTOR_SEARCH()` on embeddings | Semantic recall — catches concept overlap when tag wording differs |
| JSON/Structs in rows | Edge metadata stored inline, no join tables |
| Python sidecar memory | Active video nodes loaded at session start — near-instant traversal |

**Why 1-3 cards, not 20**

During playback the Caddie is silent — the user is consuming audio from the video. Cards surface as suggestions, not interruptions. High precision, low volume. One perfect card beats ten mediocre ones. During pause, the Caddie becomes conversational and can expand on any card on demand.

> "Dev Caddie avoids Graph Fatigue by implementing a Strict 3rd-Order Star Schema. Every suggestion is directly relevant to the current visual state, the broader technical category, or the user's active project — nothing more, nothing less."

### RSS Article Indexing for Lecture Cross-Pollination

Daily Airflow pipeline indexes every scored article with `primary_tags` and `secondary_tags` into `articles_scored`. This is the live side of the star schema — pre-ingestion bakes concept expansions into `video_segments` (stable), while `articles_scored` is re-queried fresh on every timestamp lookup (always current).

**No pre-linking between videos and articles.** Tags are the index. The YouTube player fires `timeupdate` → a BQ lookup uses `WHERE start_sec <= t AND end_sec > t` to retrieve the current segment's `primary_tags` (already computed at pre-ingestion, zero Gemini cost) → a second BQ query hits `articles_scored` by tag match. Articles published after the video was ingested are automatically discoverable — the temporal map is permanent, the article side is always live.

**Zero token cost during playback.** No video bytes sent to Gemini. No AI calls. Pure BQ reads driven by the YouTube timestamp. Gemini Live only opens the pipe on pause.

**Frontend: dual-mode rendering**

- **During playback**: plain sidebar cards — title, one-line summary, tag badge. No graph, no animation. The star schema is the *inference model*, not the visual. Cards are quiet; a force-directed graph during active watching would be distracting.
- **During pause**: star graph activates via React-Force-Graph — hub node (current segment) pinned at center, spike nodes animate in as context loads. Clicking any node triggers Gemini Live to expand on it.

**Frontend Stack (Lecture Companion — React, separate from current HTML UI)**

The existing platform UI is plain HTML/vanilla JS (`cloudrun/static/`). The Lecture Companion is built as a new React frontend — the YouTube player lifecycle hooks, Zustand state sync, and Framer Motion reveal pattern require React's component model.

| Layer | Technology | Role |
|---|---|---|
| Framework | React (Next.js) | Component state + audio/video hooks |
| Graph | React-Force-Graph 2D | Canvas-level performance, native star schema updates — new spike nodes elastic-snap into place without manual coordinate calculation |
| Animation | Framer Motion | Pre-render & Reveal pattern — nodes rendered hidden, revealed at exact audio timestamp via `animate` prop |
| State | Zustand | High-frequency sync between YouTube `timeupdate` and graph data — lightweight, non-blocking |
| Styling | Tailwind CSS | Sidebar cards: "muted" during playback, "glow" on active node during pause |

**The Zero-Lag Reveal (Framer Motion + `start_timestamp`)**

The `TransportMessageUrgentFrame` carries a `start_timestamp`. Zustand holds the current audio playhead. When playhead reaches `start_timestamp`, Framer Motion's `animate` prop triggers the reveal — nodes illuminate at the exact millisecond the agent speaks the concept name.

```
TransportMessageUrgentFrame arrives → Zustand stores {graph_payload, start_timestamp}
YouTube audio playhead reaches start_timestamp → Framer Motion animate: visible
                                               → graph nodes reveal in sidebar
```

**Canvas mode for scale**: React-Force-Graph's canvas renderer handles hundreds of nodes without dropping frames — future-proof when inference expands beyond 3rd order.

### Visual Persistence: The Engine Behind Event-Driven Segmentation

Visual Persistence is what makes segments *logical units of thought* rather than arbitrary time slices. Without it, segments are 30-second clips. With it, they are chapters.

**1. Visual State Change as Segment Boundary**

A change in visual state — new slide, cleared whiteboard, new file in IDE — is the most reliable segmentation event in technical content.

**Detection mechanism (cascade):**
1. FFmpeg extracts keyframes every ~2 seconds
2. Perceptual hash (pHash) or SSIM compares consecutive frames — similarity below threshold (>40% pixel distribution change) → candidate boundary
3. OCR verification: if the slide title area changed → confirmed boundary; if body changed but title same → same segment, new annotation (child node)
4. Transcript sliced to match confirmed visual boundaries

```
Frame similarity check → persistence holds → same segment
  (pHash / SSIM)       → persistence breaks → OCR title check
                                            → title changed: new segment boundary
                                            → title same: child annotation (Refinement edge)
                                            → transcript sliced to match (±10s sliding window)
```

Two additional noise filters run alongside the visual cascade:

- **Semantic gating**: if the transcript window is classified as non-technical content (sponsor reads, meta-commentary, off-topic tangents), the frame window is skipped entirely — no segment created regardless of visual change.
- **Sliding window alignment (±10s)**: transcript slice boundaries are aligned to the visual event with a ±10s window to absorb audio-visual desync common in live-recorded lectures where the speaker's words lag the slide transition.

**2. Cross-Modal Grounding (Resolving the "This" Problem)**

Professors say "if you move *this* here, it breaks" — useless for search in isolation. Visual Persistence fixes this: because Gemini reasons across the whole segment, it sees the architecture diagram has been persistent for 3 minutes. It grounds "this" to the specific node visible on screen.

**Grounding prompt pattern:**
> *"Based on the visual anchor at 05:00 and the spoken words 'Let's move this here,' identify exactly what 'this' refers to in the context of the diagram."*

```
Transcript: "If you move this here, it breaks."
Visual anchor: Architecture diagram, persistent since 05:00
Grounding prompt → Gemini Vision reasons across frame + transcript slice
Grounded index entry: "Moving the Load Balancer (Node A) into the Private Subnet"
```

**3. Background Inheritance → Temporal Hierarchy (Spike 1)**

Same visual background + new annotations = child node. This is how `prerequisite_ids` gets populated automatically during ingestion, without hallucinating dependency links.

| Segment | Visual | Transcript focus | Relationship |
|---|---|---|---|
| seg_05 (05:00) | Clean architecture slide | General overview | Parent |
| seg_07 (07:00) | Same slide + red circles on API Gateway | Security specifics | Child (Refinement edge) |

Gemini sees visual background persisted but transcript moved from overview to specifics → `prerequisite_ids = ['seg_05']`, edge type = `Refinement`.

**4. Event-Driven Meaning Extraction**

Segments are indexed not just by keywords but by *actions* — what happened, not just what was said.

| Event | Visual signal | Transcript signal | Index entry type |
|---|---|---|---|
| Code execution | Terminal output appears | "Let's run this" | `Action: Execute` |
| Bug fix | Line of code deleted | "That shouldn't be there" | `Action: Correction` |
| Concept intro | New slide | First mention of term | `Action: Definition` |

**The Multimodal Alignment Engine**

| Layer | Input | Logic | Output |
|---|---|---|---|
| Verbal | Transcript | Semantic chunking | Topic labels |
| Visual | Keyframes | Visual persistence check | State boundaries (segment hubs) |
| Reasoning | Both | Cross-modal grounding | Star Schema node with `visual_embedding` |

`visual_embedding` is generated from Gemini's grounded segment summary — not raw frame pixels, not raw transcript text, but the cross-modal output that knows both what was shown and what was said.

### Key Design Decisions

- **Video temporal map is permanent** — video content doesn't change.
- **Article matching is live** — daily-ingested articles always fresh, never stale.
- **Concept graph, not article graph** — pre-ingestion stores concept expansions (stable), not article links (would go stale).
- **Segment windows, not point timestamps** — `WHERE start_sec <= t AND end_sec > t` absorbs timing drift.
- **Dual-mode audio** — silent during playback (video owns the audio channel), fully conversational via Gemini Live during pause.

### BQ Schema

```sql
video_index:    { video_id, title, channel, duration_sec, ingested_at, status }

video_segments: { video_id, segment_id, start_sec, end_sec,
                  topic STRING,
                  summary STRING,
                  key_terms ARRAY<STRING>,
                  primary_tags ARRAY<STRING>,       -- drive tag-based article match
                  secondary_tags ARRAY<STRING>,
                  concepts JSON,                    -- Star Schema expansion (3 orders)
                  visual_embedding ARRAY<FLOAT64>,  -- cross-modal grounded embedding (text-embedding-004)
                  prerequisite_ids ARRAY<STRING>,   -- DAG (not single parent)
                  parent_edge_type STRING            -- Definition / Implementation / Refinement
                }

articles_scored: { article_id, url, title, summary, content,
                   primary_tags ARRAY<STRING>,
                   secondary_tags ARRAY<STRING>,
                   ai_relevance_score INT,
                   community_score INT,
                   final_score INT,
                   -- Multi-vector embeddings (text-embedding-004)
                   header_embedding ARRAY<FLOAT64>,   -- title + first paragraph: high-level intent & topic categorization
                   summary_embedding ARRAY<FLOAT64>,  -- AI-generated abstract: captures "why this matters"
                   concept_embeddings JSON,           -- 500-token semantic chunks: specific technical details in body
                   feed_ids ARRAY<STRING>,
                   published_at TIMESTAMP, ingested_at TIMESTAMP
                 }
```

### Function Calling (shared pattern with Morning Briefing)

Both features use the same Pipecat `tool_call` handler pattern:
- **Briefing**: `handle_briefing_interaction(action)` — READ_FULL or SKIP_TO_NEXT
- **Lecture**: `query_knowledge_base(concepts, timestamp)` — Gemini detects keyword, fires RAG

### Synchronized Dual-Channel Delivery (Modal Cohesion)

The hardest problem in multimodal agents is the **Asynchronicity Gap** — audio and structured data move at different speeds over the wire. A knowledge graph payload sent over HTTP will arrive before the audio buffer even starts playing, causing the visual to precede the voice.

**Orchestration vs. Stitching**

| Approach | Method | Problem |
|---|---|---|
| Client-Side Stitching | Frontend waits for audio start, then renders data | Brittle "wait" logic, adds lag |
| Server-Side Orchestration (Dev Caddie) | Sidecar packages data and audio in the same pipeline | Single source of truth |

The sidecar doesn't "emit and pray." It injects the knowledge graph payload as a `TransportMessageUrgentFrame` alongside the audio stream. In WebRTC, urgent/control frames are prioritized at the protocol level — the graph arrives at the frontend at or slightly before the audio buffer begins playing.

**The Pre-Render Pattern**

The frontend receives the graph payload and renders nodes in a hidden state. The moment audio playback starts, nodes are revealed/animated. This achieves **Zero-Lag Perception** — the visual illuminates at the exact millisecond the agent speaks the concept's name.

**Audio Buffer Latency Gotcha**

WebRTC playback has a ~100–300ms jitter buffer. A naively sent data frame may render 200ms before the voice starts.

Fix: The sidecar attaches a `start_timestamp` to the data frame. The frontend listens to the audio playhead and triggers the graph animation when it hits that timestamp. Because both audio and data originate from the same Pipecat node, the timestamps are guaranteed to match.

```
Sidecar emits:
  AudioFrame(content="...eBPF kernel bypass...")  ─┐
  TransportMessageUrgentFrame(                      ├─ same pipeline tick
    graph_payload, start_timestamp=T               ─┘
  )

Frontend:
  audio_playhead reaches T → reveal graph nodes
```

> "By utilizing a stateful orchestration node, I moved from Client-Side Stitching to Server-Side Synchronization. The Caddie emits a structured knowledge graph as an Urgent Frame alongside the audio stream, ensuring the visual representation of a concept illuminates at the exact millisecond the agent speaks its name — a unified, high-bandwidth cognitive experience."

### Application-Layer Gating (State-Driven, not Acoustic)

Standard voice AI uses VAD — a microphone threshold. Dev Caddie rejects this in favor of **state-driven gating** bound to the YouTube player lifecycle.

**The Inverse Lifecycle**

| Player State | Caddie State | Gate |
|---|---|---|
| Playing | Dormant — visually indexing only | Closed |
| Paused | Fully conversational | Open |

**Semantic vs. Acoustic Trigger**

- Acoustic (generic): "Audio energy crossed -40dB" — prone to lecturer feedback and ambient noise.
- Semantic (Dev Caddie): "The user stopped to think" — triggered by `onPause` from the YouTube player.

The gate is not guessing whether the user wants to talk. The application is *telling* the agent the conversational window is open because the primary media stream stopped.

**Why this matters**

- **Clean VAD**: Zero risk of the agent hearing the video audio and responding to the lecturer.
- **Zero token bleed**: No audio streamed to Gemini during 60 minutes of passive watching — pipe only opens on pause.
- **Instant response**: No warm-up latency; sidecar is pre-loaded with the user's context and ready the moment pause fires.

### Scale & Sovereignty

Self-hosting the sidecar trades Pipecat Cloud's global edge network for data sovereignty. At scale, the missing edge is recovered via a **Regional Sidecar Model**.

**Regional Orchestration**

Deploy the Pipecat sidecar as a container (Cloud Run or GKE) across regions (`us-central1`, `europe-west1`, etc.) behind Google Cloud Global HTTP(S) Load Balancing. Users connect to the nearest node — same low-latency feel as a managed edge, but the container and BigQuery connection stay owned.

**The Brain vs. The Eyes**

- **Brain (BigQuery)**: Global, centralized source of truth — user feeds, scored articles, pre-ingested video graphs.
- **Eyes (Regional Sidecars)**: Transient WebRTC workers. Query the Brain as needed, warm-cached per user session.

**Identity-Driven Personalization**

Because the sidecar lives next to the data, stateful personalization is a query, not an API contract:

- On session start, the sidecar pulls the user's RSS interest profile and scored feed from BQ.
- When the user pauses the video, cross-pollination is filtered by *their* GitHub commits, saved articles, and topic history — not a generic feed.
- A managed stateless cloud service would require passing this entire user context on every API turn. Self-hosting means the agent already knows.

> "A generic managed endpoint has no concept of the host application's state. It sees a stream as a stream. By self-hosting the orchestration node, the AI's lifecycle is bound to the video player's events — not a microphone threshold. This ensures the Caddie is silent during consumption and instant during reflection, eliminating acoustic noise and token bleed that plague always-on agents."

## Video Lecture Notes (LectureService)

Converts YouTube videos into structured study guides using Gemini 2.5 Flash.

### Workflow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           process_video(url)                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  1. CHECK BIGQUERY CACHE                                                    │
│     └─→ If exists & !force → return early (FREE)                           │
│                                                                             │
│  2. DOWNLOAD VIDEO (yt-dlp)                          ← Local: /tmp/        │
│     └─→ Get video file + title                                              │
│                                                                             │
│  3. CHECK RAW CACHE (GCS)                            ← gs://bucket/raw_cache│
│     ├─→ HIT:  Load notes_bundle (FREE)              ⚡ Skip Step 4          │
│     └─→ MISS: Continue to Step 4                                            │
│                                                                             │
│  4. GENERATE NOTES (Gemini 2.5 Flash)                ← 💰 ~$0.30/video      │
│     ├─→ Upload video to GCS                                                 │
│     ├─→ Pass 1: Video → Markdown (video tokens)                             │
│     ├─→ Pass 2: Insert slide markers (text only)                            │
│     ├─→ Pass 3: Parse JSON metadata (text only)                             │
│     └─→ Save to RAW CACHE (GCS)                     💾 For next run         │
│                                                                             │
│  5. PROCESS SLIDES (ffmpeg + Gemini Vision)          ← ~$0.01/frame         │
│     ├─→ Extract frames at [SLIDE: MM:SS] timestamps                         │
│     ├─→ Validate each frame (skip_validation=True to bypass)                │
│     └─→ Upload frames to GCS (permanent)                                    │
│                                                                             │
│  6. CLEANUP                                                                 │
│     ├─→ Delete temp video from GCS                                          │
│     └─→ Delete local /tmp file                                              │
│                                                                             │
│  7. SAVE TO BIGQUERY                                 ← Final cache          │
│     └─→ article_id, title, summary, content (markdown)                      │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Cost Optimization

| Strategy | Savings |
|----------|---------|
| BigQuery cache (final notes) | Skip entire pipeline if exists |
| GCS raw cache (Gemini response) | Skip Step 4 (~$0.30/video) |
| `skip_validation=True` | Skip per-frame Gemini calls |
| `mock=True` | Skip all Gemini calls (dev mode) |

### Entry Points

- **Script**: `python scripts/video_lecture_notes.py <url>`
- **API**: `POST /api/lectures` (Cloud Run)
- **UI**: Lecture Notes page in dashboard

## Deployment (Public)

- **Cloud Run**: `deploy_dev_caddie.sh`
- **Sidecar**: internal deployment details are private, but Cloud Run communicates via a simple `/start` + `/stop` API.
