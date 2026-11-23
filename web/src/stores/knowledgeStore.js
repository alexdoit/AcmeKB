import { defineStore } from 'pinia'
import * as api from '../services/api'

export const useKnowledgeStore = defineStore('knowledge', {
  state: () => ({
    chunks: [],
    loading: false,
    error: null,
    filters: { search: '', docType: '', app: '', module: '' }
  }),

  getters: {
    distinctDocTypes: (s) => uniqueSorted(s.chunks.map((c) => c.DocType)),
    distinctApps: (s) => uniqueSorted(s.chunks.map((c) => c.AppName)),
    distinctModules: (s) => uniqueSorted(s.chunks.map((c) => c.ModuleName)),
    hasActiveFilters: (s) =>
      Boolean(s.filters.search || s.filters.docType || s.filters.app || s.filters.module),
    // Free-text search is client-side (DAB $filter has no string functions).
    visibleChunks: (s) => {
      const term = s.filters.search.trim().toLowerCase()
      if (!term) return s.chunks
      return s.chunks.filter((c) =>
        [c.Title, c.SearchContext, c.MainContent].some(
          (field) => field && String(field).toLowerCase().includes(term)
        )
      )
    }
  },

  actions: {
    async fetch() {
      this.loading = true
      this.error = null
      try {
        this.chunks = await api.getKnowledgeChunks(this.filters)
      } catch (e) {
        this.error = e.response?.data?.message || e.message
      } finally {
        this.loading = false
      }
    },

    setFilter(key, value) {
      this.filters[key] = value
    },

    resetFilters() {
      this.filters = { search: '', docType: '', app: '', module: '' }
    },

    async saveChunk(chunkId, payload) {
      const updated = await api.patchKnowledgeChunk(chunkId, payload)
      const index = this.chunks.findIndex((c) => c.ChunkID === chunkId)
      if (index !== -1) this.chunks[index] = { ...this.chunks[index], ...updated }
      return updated
    }
  }
})

function uniqueSorted(values) {
  return [...new Set(values.filter(Boolean))].sort((a, b) => a.localeCompare(b))
}
