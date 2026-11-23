<template>
  <!-- Card list on mobile -->
  <div class="space-y-2 md:hidden">
    <button
      v-for="chunk in chunks"
      :key="chunk.ChunkID"
      class="w-full rounded-xl border border-slate-200 bg-white p-3.5 text-left shadow-sm transition active:bg-slate-50"
      @click="$emit('open', chunk)"
    >
      <div class="flex flex-wrap items-center gap-1.5">
        <Badge :label="chunk.DocType" variant="indigo" />
        <Badge v-if="chunk.AppVersion" :label="`v${chunk.AppVersion}`" variant="slate" />
      </div>
      <div class="mt-2 text-sm font-medium leading-5 text-zinc-900">{{ chunk.Title }}</div>
      <p class="mt-1 line-clamp-2 text-xs leading-4 text-zinc-500">
        {{ snippet(chunk) }}
      </p>
      <div class="mt-2 text-[11px] text-zinc-400">
        {{ chunk.AppName }} / {{ chunk.ModuleName }} · {{ formatDate(chunk.EventDate) }}
      </div>
    </button>

    <EmptyState v-if="!loading && !chunks.length" />
  </div>

  <!-- Table on md+ -->
  <div class="hidden overflow-hidden rounded-xl border border-slate-200 bg-white shadow-sm md:block">
    <table class="w-full text-sm">
      <thead>
        <tr class="border-b border-slate-200 bg-slate-50 text-left text-[11px] uppercase tracking-wider text-zinc-400">
          <th class="px-4 py-2.5 font-semibold">Title</th>
          <th class="px-4 py-2.5 font-semibold">Application</th>
          <th class="px-4 py-2.5 font-semibold">Module</th>
          <th class="px-4 py-2.5 font-semibold">Type</th>
          <th class="px-4 py-2.5 font-semibold">Version</th>
          <th class="px-4 py-2.5 font-semibold">Date</th>
        </tr>
      </thead>
      <tbody>
        <tr
          v-for="chunk in chunks"
          :key="chunk.ChunkID"
          class="cursor-pointer border-b border-slate-100 transition last:border-0 hover:bg-indigo-50/40"
          @click="$emit('open', chunk)"
        >
          <td class="max-w-md px-4 py-3">
            <div class="truncate font-medium text-zinc-900">{{ chunk.Title }}</div>
            <div class="mt-0.5 line-clamp-1 text-xs text-zinc-400">{{ snippet(chunk) }}</div>
          </td>
          <td class="px-4 py-3 text-zinc-600">{{ chunk.AppName }}</td>
          <td class="px-4 py-3 text-zinc-600">{{ chunk.ModuleName }}</td>
          <td class="px-4 py-3"><Badge :label="chunk.DocType" variant="indigo" /></td>
          <td class="px-4 py-3 text-zinc-600">{{ chunk.AppVersion || '—' }}</td>
          <td class="whitespace-nowrap px-4 py-3 text-zinc-500">{{ formatDate(chunk.EventDate) }}</td>
        </tr>
      </tbody>
    </table>

    <EmptyState v-if="!loading && !chunks.length" class="rounded-none border-0 shadow-none" />
  </div>

  <!-- Loading skeleton -->
  <div v-if="loading" class="space-y-2">
    <div v-for="n in 5" :key="n" class="h-16 animate-pulse rounded-xl bg-slate-200/70" />
  </div>
</template>

<script setup>
import Badge from '../shared/Badge.vue'
import EmptyState from '../shared/EmptyState.vue'

defineProps({ chunks: { type: Array, required: true }, loading: { type: Boolean, default: false } })
defineEmits(['open'])

const dateFmt = new Intl.DateTimeFormat('en-GB', { day: '2-digit', month: '2-digit', year: 'numeric' })

function formatDate(iso) {
  if (!iso) return '—'
  try {
    return dateFmt.format(new Date(iso))
  } catch {
    return iso
  }
}

function snippet(chunk) {
  const text = (chunk.MainContent || chunk.SearchContext || '').replace(/\s+/g, ' ').trim()
  return text.length > 140 ? `${text.slice(0, 140)}…` : text
}
</script>
