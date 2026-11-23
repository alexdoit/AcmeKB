<template>
  <div class="flex flex-col gap-2 sm:flex-row sm:items-center">
    <!-- Search with debounce -->
    <div class="relative flex-1 sm:max-w-xs">
      <Search :size="15" class="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-zinc-400" />
      <input
        v-model="search"
        type="text"
        placeholder="Search title and content…"
        class="w-full rounded-lg border border-slate-200 bg-white py-2 pl-9 pr-8 text-sm text-zinc-800 shadow-sm outline-none transition placeholder:text-zinc-400 focus:border-indigo-400 focus:ring-2 focus:ring-indigo-100"
      />
      <button
        v-if="search"
        class="absolute right-2 top-1/2 -translate-y-1/2 rounded p-0.5 text-zinc-400 hover:text-zinc-600"
        aria-label="Clear search"
        @click="search = ''"
      >
        <X :size="14" />
      </button>
    </div>

    <select
      v-model="filters.docType"
      class="rounded-lg border border-slate-200 bg-white px-3 py-2 text-sm text-zinc-700 shadow-sm outline-none transition focus:border-indigo-400 focus:ring-2 focus:ring-indigo-100 sm:w-40"
    >
      <option value="">Document type: all</option>
      <option v-for="t in store.distinctDocTypes" :key="t" :value="t">{{ t }}</option>
    </select>

    <select
      v-model="filters.app"
      class="rounded-lg border border-slate-200 bg-white px-3 py-2 text-sm text-zinc-700 shadow-sm outline-none transition focus:border-indigo-400 focus:ring-2 focus:ring-indigo-100 sm:w-36"
    >
      <option value="">Application: all</option>
      <option v-for="a in store.distinctApps" :key="a" :value="a">{{ a }}</option>
    </select>

    <select
      v-model="filters.module"
      class="rounded-lg border border-slate-200 bg-white px-3 py-2 text-sm text-zinc-700 shadow-sm outline-none transition focus:border-indigo-400 focus:ring-2 focus:ring-indigo-100 sm:w-36"
    >
      <option value="">Module: all</option>
      <option v-for="m in store.distinctModules" :key="m" :value="m">{{ m }}</option>
    </select>

    <button
      v-if="store.hasActiveFilters"
      class="self-start rounded-lg px-2.5 py-2 text-xs font-medium text-indigo-600 transition hover:bg-indigo-50 active:bg-indigo-100 sm:self-auto"
      @click="onReset"
    >
      Reset
    </button>
  </div>
</template>

<script setup>
import { ref, watch } from 'vue'
import { Search, X } from '@lucide/vue'
import { useKnowledgeStore } from '../../stores/knowledgeStore'

const store = useKnowledgeStore()

const search = ref(store.filters.search)
const filters = store.filters

let debounceTimer = null

// Debounced search, applied client-side (DAB $filter has no string functions).
watch(search, (value) => {
  clearTimeout(debounceTimer)
  debounceTimer = setTimeout(() => {
    if (store.filters.search !== value) store.setFilter('search', value)
  }, 300)
})

// Server-side eq filters trigger a fetch.
watch(
  () => [store.filters.docType, store.filters.app, store.filters.module],
  () => store.fetch()
)

function onReset() {
  search.value = ''
  store.resetFilters() // the eq-filter watch triggers the refetch
}
</script>
