import axios from 'axios'

// Same-origin /api by default: in dev, Vite proxies /api to the Data API
// builder (http://localhost:5000), so a phone on the LAN can reach the app
// via the PC's LAN IP. VITE_API_BASE_URL (.env, optional) forces an absolute
// URL for production builds served from another origin.
const client = axios.create({
  baseURL: import.meta.env.VITE_API_BASE_URL || '/api',
  timeout: 240000 // Ollama skill runs can take up to ~220s
})

/* --------------------------------- KnowledgeChunks --------------------------------- */

// This DAB build rejects OData string functions in $filter (substringof /
// contains / startswith all return 400), so free-text search is applied
// client-side in knowledgeStore; only eq conditions are sent to the API.
export function getKnowledgeChunks({ docType = '', app = '', module = '', first = 500 } = {}) {
  const parts = []
  if (docType) parts.push(`DocType eq '${odataEscape(docType)}'`)
  if (app) parts.push(`AppName eq '${odataEscape(app)}'`)
  if (module) parts.push(`ModuleName eq '${odataEscape(module)}'`)

  const params = { $first: first, $orderby: 'EventDate desc, ChunkID desc' }
  if (parts.length) params.$filter = parts.join(' and ')

  return client.get('/KnowledgeChunks', { params }).then((r) => r.data.value)
}

// Writes need the "editor" role of the API. With the Simulator auth provider
// (development) DAB takes the role from this header; with a real identity
// provider the signed-in user must also hold the role.
const editor = { headers: { 'X-MS-API-ROLE': 'editor' } }

// Note: edits made through the REST API do not refresh the chunk embeddings.
export function patchKnowledgeChunk(chunkId, payload) {
  return client.patch(`/KnowledgeChunks/ChunkID/${chunkId}`, payload, editor).then((r) => r.data)
}

export function postKnowledgeChunk(payload) {
  return client.post('/KnowledgeChunks', payload, editor).then((r) => r.data)
}

/* ---------------------------------- ChatSessions ---------------------------------- */

export function getChatSessions() {
  return client
    .get('/ChatSessions', { params: { $orderby: 'CreatedAt desc' } })
    .then((r) => r.data.value)
}

export function deleteChatSession(sessionId) {
  return client.delete(`/ChatSessions/SessionID/${sessionId}`, editor).then((r) => r.data)
}

/* ---------------------------------- ChatMessages ---------------------------------- */

// SessionID is Edm.Guid — do NOT wrap it in quotes inside $filter, DAB
// rejects Edm.String comparisons with 400.
export function getChatMessages(sessionId) {
  return client
    .get('/ChatMessages', {
      params: {
        $filter: `SessionID eq ${sessionId}`,
        $orderby: 'CreatedAt asc, MessageID asc'
      }
    })
    .then((r) => r.data.value)
}

/* --------------------------------- Ollama engine ---------------------------------- */

export function executeOllamaSkillEngine(payload) {
  return client.post('/ExecuteOllamaSkillEngine', payload).then((r) => r.data)
}

/* ----------------------------------- Helpers -------------------------------------- */

function odataEscape(value) {
  return String(value).replace(/'/g, "''")
}
