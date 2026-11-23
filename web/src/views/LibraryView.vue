<template>
  <div class="flex h-full flex-col">
    <!-- Header -->
    <header class="border-b border-slate-200 bg-white px-4 py-3 sm:px-6">
      <div class="flex items-baseline justify-between gap-3">
        <div>
          <h1 class="text-sm font-semibold text-zinc-900 sm:text-base">Knowledge base</h1>
          <p class="text-[11px] text-zinc-400">
            Release notes, helpdesk tickets and technical documentation
          </p>
        </div>
        <span v-if="!store.loading" class="shrink-0 text-xs text-zinc-400">
          {{ store.visibleChunks.length }} chunks
        </span>
      </div>

      <div class="mt-3">
        <FilterBar />
      </div>
    </header>

    <!-- Content -->
    <div class="min-h-0 flex-1 overflow-y-auto px-3 py-4 sm:px-6">
      <div class="mx-auto max-w-5xl">
        <div v-if="store.error" class="mb-3 rounded-lg border border-rose-200 bg-rose-50 px-3 py-2 text-xs text-rose-700">
          {{ store.error }}
        </div>
        <KnowledgeTable :chunks="store.visibleChunks" :loading="store.loading" @open="selected = $event" />
      </div>
    </div>

    <DocumentViewer :chunk="selected" @close="selected = null" />
  </div>
</template>

<script setup>
import { ref, onMounted } from 'vue'
import { useKnowledgeStore } from '../stores/knowledgeStore'
import FilterBar from '../components/library/FilterBar.vue'
import KnowledgeTable from '../components/library/KnowledgeTable.vue'
import DocumentViewer from '../components/library/DocumentViewer.vue'

const store = useKnowledgeStore()
const selected = ref(null)

onMounted(() => {
  if (!store.chunks.length && !store.loading) store.fetch()
})
</script>
