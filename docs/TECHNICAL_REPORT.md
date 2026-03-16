# Dev Caddie — Technical Submission (Judges)

> A distributed hybrid system that curates, scores, and narrates high‑signal engineering reads, plus structured video lecture notes.

## 1) Executive Summary
Dev Caddie turns 500+ daily technical articles into a short voice briefing. It blends Gemini relevance scoring with community signals (HN/Lobsters) to avoid surface‑level picks, then narrates top stories through a Gemini Live + Daily voice stack with barge‑in controls.  
It also generates structured, time‑indexed lecture notes with snapshots so students can scan, search, and verify key moments fast.

## 2) System Architecture (Hybrid)
**Cloud Run** (UI + API) orchestrates sessions and serves data.  
**VM Sidecar** (Pipecat + Daily + Gemini Live) handles low‑latency audio streaming.  
**Airflow + BigQuery** handle ingestion, scoring, ranking, and briefing script generation.

```
RSS Feeds (OPML)
  → Airflow DAG
    → Scoring (Gemini + HN/Lobsters)
      → BigQuery (articles_scored)
        ├─ Daily Briefing Script → Cloud Run API → Sidecar VM → Browser UI
        ├─ Smart Feed Chat (StruQ) → Cloud Run API → BigQuery → Browser UI
        └─ Smart Feeds Dashboard → Cloud Run API → Browser UI
```

## 3) Core Innovations
### 3.1 Triple‑Signal Scoring (AI + Community + Feed Convergence)
AI relevance alone can't distinguish an obscure tutorial from a battle‑tested engineering post.
Dev Caddie blends AI relevance, community signals, and feed convergence — with **viral override** when engagement spikes.

**Scoring Components**
- **AI relevance**: Gemini scores semantic fit (0–100) and emits structured fields (topics, actionability, content type).
- **Community**: HN + Lobsters points/comments normalized into a 0–100 signal.
- **Feed convergence**: When 3+ RSS feeds independently publish the same article, that cross-ecosystem agreement is a signal. +3 per feed beyond 2, capped at +10.

**Confidence‑based weighting**
Weights depend on how much social signal exists:
```
high   → (AI 0.5, Community 0.5)   # strong signals on both platforms
medium → (AI 0.7, Community 0.3)   # signal on one platform
low    → (AI 0.9, Community 0.1)   # minimal social signal
```

**Viral override**
When community score crosses a threshold (e.g., ≥70), weights flip (AI 0.3 / Community 0.7).
This ensures viral posts surface without letting off‑topic content dominate (AI relevance floor still applies).

**Novelty scoring (corrected)**
The scorer penalizes *derivative content* (same argument, reworded) — not *topic convergence*. An article on a widely-covered topic still scores on its own originality. Topic convergence across feeds is a positive signal, not a penalty.

**Lineage tracking**
Every article carries a `feed_ids ARRAY<STRING>` — all RSS sources that published it. The rescore service re-reads this on each cycle, so articles that spread across the ecosystem are rescored upward automatically.

### 3.2 Deterministic Briefing + Live Q&A
The briefing is a **deterministic script** (greeting + 5 summaries + closing) read verbatim by Gemini Live.  
After each article, a gate opens for Q&A, then closes for the next scripted segment.

**Why deterministic**  
The script is generated once per day, stored in BigQuery, and read verbatim to avoid hallucinations and keep timing predictable.

**Mode switching**
- **Narration**: deterministic, gate closed
- **Q&A**: nondeterministic, gate open

This separation prevents Gemini Live context resets during the scripted flow.

### 3.3 Barge‑In Gate + UI Sync
`allow_interruptions` toggles when the user can interrupt.  
Gate status is pushed to the UI so users see “Barge‑in: On/Off” in real time.

**Signal path**
- Pipecat transport → Daily app‑message  
`{ "type": "gate-status", "allow_interruptions": true|false }`

**Behavior**
- Gate closed during narration to prevent accidental interruptions.
- Gate open at article boundaries for questions and clarification.

### 3.4 Smart Feed Chat (StruQ)
Natural language → **structured intent** → parameterized BigQuery queries.  
No raw SQL generation from user input (prevents injection).

**StruQ flow**
1. Gemini returns a strict JSON schema (topics, time range, min score, content type).
2. Query builder maps intent → parameterized SQL templates.
3. BigQuery executes with explicit params only.

## 4) Lecture Notes: Structured, Time‑Indexed
Lecture processing produces JSON + snapshots:
- Snapshots stored in GCS
- Notes stored in BigQuery
- UI renders time‑indexed notes and slide references

**Pipeline (simplified)**
1. FFmpeg extracts frames at fixed intervals.  
2. Gemini generates markdown notes with `[SLIDE: MM:SS]` anchors.  
3. Notes + metadata stored in `lecture_notes` with snapshot pointers.

### Why this solves the Ivy League problem
1. **Visual memory anchor**: snapshots appear next to notes; no scrubbing through 90‑minute videos.  
2. **Searchable deep‑knowledge**: search a keyword and jump to the *visual evidence* of that moment.  
3. **Pre‑read advantage**: scan Top‑5 takeaways + Cornell notes in minutes before seminar.

## 5) Security & Safety
- **Prompt‑Injection Defense (5 layers)**: input validation → secure prompts → strict schema output → output validation → rate limiting  
- **Budget Guard**: per‑IP limits + daily budget cap (Firestore)

**Defense layers (summary)**
1. **Input validation**: regex detection of jailbreaks, injection patterns, malformed URLs.
2. **Prompt construction**: user input wrapped in strict delimiters.
3. **Structured output**: Gemini response schema enforced by Pydantic.
4. **Output validation**: prompt‑leak detection + schema enforcement.
5. **Rate limiting**: per‑IP + global budget caps.

## 6) Observability
Key metrics for briefing quality:
- TTFB (P50/P95)
- Token usage per turn
- Turn duration + interruption rate
- Session health

**Collection**
- Pipecat metrics (TTFB + token usage) + turn tracking for duration/interrupts.
- Stored in BQ for UI rendering and historical analysis.

## 7) Future Enhancements (Roadmap)
### 7.1 Barge‑In Visual Briefing (Gemini Live)
FFmpeg streams raw video into Gemini Live so users can ask, “What was on that slide two minutes ago?”

### 7.2 AI‑Driven “Director’s Cut”
Gemini marks high‑signal moments; FFmpeg crops/zooms and assembles TL;DR highlight reels.

### 7.3 Visual Knowledge Graphing
Detect visual entities (logos, formulas) and store embeddings; search “every time Docker Compose appeared on screen.”

### 7.4 Edge‑Accelerated Video Processing
Offload FFmpeg to client/edge to reduce cloud compute while Gemini handles reasoning.

## 8) Feature Roadmap (Current vs Future)
| Feature | Current (v1.0) | Future (v2.0) |
|---|---|---|
| Snapshots | Periodic | Event‑driven (slide changes) |
| Notes | Static Markdown | Searchable data objects |
| Audio | Pre‑generated TTS | Live conversational briefing |
| Video | Storage only | Dynamic highlight generation |

---
**Contact:** Submitted for judges’ review only.
