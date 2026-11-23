import { defineStore } from 'pinia'
import * as api from '../services/api'

export const useChatStore = defineStore('chat', {
  state: () => ({
    sessions: [],
    activeSession: null, // { SessionID, Title, CreatedAt }
    messages: [], // flat ChatMessages list (user/assistant/system/tool)
    isSending: false,
    error: null
  }),

  getters: {
    hasActiveSession: (s) => Boolean(s.activeSession?.SessionID)
  },

  actions: {
    async fetchSessions() {
      try {
        this.sessions = await api.getChatSessions()
      } catch (e) {
        this.error = e.response?.data?.message || e.message
      }
    },

    startNewChat() {
      this.activeSession = null
      this.messages = []
      this.error = null
    },

    async selectSession(session) {
      this.activeSession = session
      this.messages = []
      this.error = null
      if (!session.SessionID) return
      try {
        this.messages = await api.getChatMessages(session.SessionID)
      } catch (e) {
        this.error = e.response?.data?.message || e.message
      }
    },

    async sendPrompt(text) {
      const prompt = text.trim()
      if (!prompt || this.isSending) return

      // Optimistic local user bubble.
      this.messages = [...this.messages, { Role: 'user', Content: prompt }]
      this.isSending = true
      this.error = null

      // First prompt: send ONLY UserPrompt (engine creates the session).
      // Follow-ups: pass SessionID + UserPrompt.
      const isFirstPrompt = !this.activeSession?.SessionID
      const payload = isFirstPrompt
        ? { UserPrompt: prompt }
        : { SessionID: this.activeSession.SessionID, UserPrompt: prompt }

      try {
        const engine = await api.executeOllamaSkillEngine(payload)
        const { sessionId, finalResponse } = parseEngineResponse(engine)

        if (sessionId) {
          const known = this.sessions.find((s) => s.SessionID === sessionId)
          this.activeSession = known || {
            SessionID: sessionId,
            Title: prompt.slice(0, 60),
            CreatedAt: new Date().toISOString()
          }
        }

        // Pull the full trace (system / tool calls / tool outputs / assistant)
        // from the server and refresh the session list.
        if (this.activeSession?.SessionID) {
          this.messages = await api
            .getChatMessages(this.activeSession.SessionID)
            .catch(() => this.messages)
          this.sessions = await api.getChatSessions().catch(() => this.sessions)
        } else if (finalResponse) {
          this.messages = [...this.messages, { Role: 'assistant', Content: finalResponse }]
        }
      } catch (e) {
        this.error = e.response?.data?.message || e.message
      } finally {
        this.isSending = false
      }
    },

    async deleteSession(session) {
      await api.deleteChatSession(session.SessionID)
      this.sessions = this.sessions.filter((s) => s.SessionID !== session.SessionID)
      if (this.activeSession?.SessionID === session.SessionID) this.startNewChat()
    }
  }
})

// The engine may return a JSON object or a JSON string (possibly wrapped in
// markdown code fences). Extract SessionID / FinalResponse with a safe
// fallback to the raw text.
export function parseEngineResponse(raw) {
  // DAB wraps stored-procedure results in an envelope: { value: [ ... ] }
  let data = raw
  if (data && Array.isArray(data.value)) data = data.value[0]
  if (typeof data === 'string') {
    let text = data.trim()
    const fenced = text.match(/```(?:json)?\s*([\s\S]*?)```/)
    if (fenced) text = fenced[1].trim()
    try {
      data = JSON.parse(text)
    } catch {
      return { sessionId: null, finalResponse: raw.trim() }
    }
  }
  return {
    sessionId: data?.SessionID ?? null,
    finalResponse: data?.FinalResponse ?? (typeof raw === 'string' ? raw.trim() : null),
    totalSteps: data?.TotalStepsExecuted ?? null
  }
}
