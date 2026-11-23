# AcmeKB

A retrieval-augmented (RAG) knowledge base and tool-calling AI agent that live **inside SQL Server 2025**.
Embeddings, hybrid search and the agent loop are T-SQL stored procedures; the model runs locally in
[Ollama](https://ollama.com). A small Vue app talks to the database through
[Data API builder](https://learn.microsoft.com/azure/data-api-builder/) (DAB) — there is no custom backend.

The demo data describes **Acme Helpdesk**, a fictional help desk product: 26 resolved support tickets,
7 release notes and 6 technical documents. All of it is made up.

## Architecture

```
 Vue 3 app (web/)          Data API builder            SQL Server 2025                      Ollama
 ───────────────          ────────────────           ───────────────────────────          ─────────────────
 Chat, Library  ──REST──▶  /api/KnowledgeChunks  ──▶   tables (read)
                           /api/ChatSessions      ──▶
                           /api/ExecuteOllama...  ──▶   sp_ExecuteOllamaSkillEngine
                                                          │  agent loop (max 10 steps)
                                                          ├─ sp_invoke_external_rest_endpoint ──▶ /api/chat  (gemma4:e4b)
                                                          ├─ sp_LoadSkill      (tools on demand)
                                                          └─ sp_SearchKnowledgeBase
                                                               ├─ AI_GENERATE_EMBEDDINGS ────────▶ /api/embed (qwen3-embedding:0.6b)
                                                               ├─ VECTOR_DISTANCE (cosine)
                                                               ├─ FREETEXTTABLE (full-text)
                                                               └─ Reciprocal Rank Fusion
```

### How a question is answered

1. The app calls `POST /api/ExecuteOllamaSkillEngine` with `UserPrompt` (and `SessionID` for follow-ups).
2. The engine builds the system prompt with the **skill catalog** (`SkillRegistry`) and gives the model one tool:
   `sp_LoadSkill`.
3. The model loads the skill it needs (for example `KnowledgeSearch`); `sp_LoadSkill` returns the tool schemas from
   `SkillTools`, and the engine adds them to the tool list of the next request.
4. The model calls `sp_SearchKnowledgeBase`. The search embeds the question, takes the best vector match per chunk
   (`MainContent` and `SearchContext` vectors), runs `FREETEXTTABLE` in parallel and fuses both rankings with RRF.
5. The model answers with the retrieved chunks. Every step is stored in `ChatMessages` and `OllamaLogs`.

### Guard rails in the engine

- The model can only run tools that were exposed to it in the current turn (`dbo.fn_IsToolAllowed`), so it cannot
  `EXEC` arbitrary procedures.
- Model name, Ollama URL and system prompt are constants inside the procedure, not parameters: API callers cannot
  point SQL Server at another URL or replace the prompt.
- `MaxIterations` is clamped to 1..10; hitting the limit returns an explicit message.
- JSON is parsed with `OPENJSON ... WITH (NVARCHAR(MAX))` and text is built with `CONCAT`
  (`JSON_VALUE` silently returns `NULL` above 4,000 characters, `FORMATMESSAGE` truncates at 2,047).

## Repository layout

| Path | What |
| --- | --- |
| `db/01_schema.sql` | Database, tables, full-text index, `EXTERNAL MODEL`, API role |
| `db/02_procs.sql` | Engine, search, ingest procedures, grants |
| `db/03_seed.sql` | Skill registry and the fictional Acme Helpdesk data (loaded through the procedures) |
| `db/deploy.ps1` | Runs the scripts and the tests with `sqlcmd` |
| `tests/04_tests.sql` | 12 procedure tests (writes rolled back) |
| `tests/05_engine_test.sql` | End-to-end agent test against the real model |
| `dab-config.json` | Data API builder entities and role permissions |
| `web/` | Vue 3 + Vite + Tailwind front end |

## Prerequisites

- **SQL Server 2025** (any edition, Developer is fine) with the **Full-Text Search** feature.
- Server option `external rest endpoint enabled` turned on (needs sysadmin):
  ```sql
  EXEC sp_configure 'external rest endpoint enabled', 1;
  RECONFIGURE;
  ```
- **Ollama** with the models:
  ```
  ollama pull qwen3-embedding:0.6b
  ollama pull gemma4:e4b
  ```
- **HTTPS in front of Ollama.** SQL Server only calls `https://` endpoints, and Ollama listens on plain HTTP
  (port 11434). A local reverse proxy with a trusted certificate solves it, for example
  [Caddy](https://caddyserver.com) (`tls internal` + `caddy trust` installs its local CA):
  ```
  localhost {
    tls internal
    reverse_proxy /api/* 127.0.0.1:11434
  }
  ```
  The scripts expect Ollama at `https://localhost/api/embed` and `https://localhost/api/chat`.
- [`sqlcmd`](https://learn.microsoft.com/sql/tools/sqlcmd/sqlcmd-utility),
  [Data API builder 2.1.5](https://learn.microsoft.com/azure/data-api-builder/) (`dotnet tool install -g Microsoft.DataApiBuilder`),
  Node.js 20.19+ or 22.12+ (Vite 8).

To use other models, change `MODEL` in `CREATE EXTERNAL MODEL` (`01_schema.sql`, vector size `VECTOR(1024)` must match)
and `@ModelName` in `sp_ExecuteOllamaSkillEngine` (`02_procs.sql`).

## Deploy

```powershell
cd db
.\deploy.ps1                                  # default instance, Windows authentication
.\deploy.ps1 -Server 'localhost\MYINSTANCE'   # named instance
.\deploy.ps1 -SkipEngineTest                  # skip the slow end-to-end test
```

The scripts are idempotent (objects are created when missing, procedures with `CREATE OR ALTER`);
`03_seed.sql` replaces the Acme data on every run.

## Run the API and the app

```powershell
copy .env.example .env      # then set ACMEKB_CONNECTION_STRING (server / instance name)
dab start -c dab-config.json

cd web
npm ci
npm run dev                 # http://localhost:5173, /api is proxied to DAB on :5000
```

## Permissions

### API roles (Data API builder)

| Role | KnowledgeChunks | ChatSessions | ChatMessages | ExecuteOllamaSkillEngine |
| --- | --- | --- | --- | --- |
| `anonymous` | read | read | read | execute |
| `authenticated` | read | read | read | execute |
| `editor` | read, create, update | read, delete | read | execute |

Nobody can delete knowledge chunks or write chat history directly; only the engine writes conversations.
`OllamaLogs`, embeddings and the skill tables are not exposed at all. The executed procedure is reachable with
`POST` only.

`dab-config.json` uses the **Simulator** authentication provider, which is for development only: every request is
treated as authenticated, and the role is picked with the `X-MS-API-ROLE` header (the app sends `editor` for edits
and deletes). For a real deployment switch `runtime.host.authentication` to `EntraID` (or another JWT provider),
set `mode` to `production` and assign the `editor` role to users in the identity provider.

### Least privilege in the database

`01_schema.sql` creates the database role `acmekb_api` with exactly what the API needs: `SELECT` on the three tables,
`INSERT`/`UPDATE` on chunks, `DELETE` on sessions, `EXECUTE` on the engine and the tool procedures,
`EXECUTE ANY EXTERNAL ENDPOINT` and `EXECUTE` on the embedding model. The tool procedures need explicit grants
because the engine calls them through `sp_executesql`, which breaks ownership chaining. Test `T7` checks the role.

With Windows authentication (as in `.env.example`) DAB runs with your own rights. To run it with the role,
create a login and add it to the role:

```sql
CREATE LOGIN acmekb_api WITH PASSWORD = '<strong password>';
USE AcmeKB;
CREATE USER acmekb_api FOR LOGIN acmekb_api;
ALTER ROLE acmekb_api ADD MEMBER acmekb_api;
```

and use the SQL login connection string from `.env.example`.

## Known limitations

- Chunks created or edited through the REST API (`editor` role) do not get new embeddings: vector search uses the
  old vector (or none) until the chunk is re-ingested through `sp_AddTechnicalDoc` / `sp_AddHelpdeskTicket`.
- The engine call is synchronous and can take a minute or more on a laptop GPU; DAB's command timeout is set
  to 240 seconds in the connection string.
- `anonymous` can run the engine, which means anyone who reaches the API can use your GPU. Keep DAB on localhost
  or require authentication for `ExecuteOllamaSkillEngine` outside a demo.
