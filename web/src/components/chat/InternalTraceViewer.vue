<template>
  <div class="rounded-lg border border-dashed border-slate-300 bg-slate-50/80">
    <button class="flex w-full items-center gap-2 px-3 py-2 text-left" @click="expanded = !expanded">
      <Wrench :size="14" class="shrink-0 text-zinc-400" />
      <span class="min-w-0 flex-1 truncate text-xs font-medium text-zinc-500">
        Model reasoning steps and tool calls
      </span>
      <span class="hidden shrink-0 items-center gap-1 sm:flex">
        <span
          v-for="badge in badges"
          :key="badge"
          class="rounded-full bg-white px-2 py-0.5 text-[10px] font-medium text-zinc-500 ring-1 ring-slate-200"
        >
          {{ badge }}
        </span>
      </span>
      <span class="shrink-0 text-[11px] font-medium text-indigo-600">
        {{ expanded ? 'Collapse' : 'Details' }}
      </span>
      <ChevronDown
        :size="14"
        class="shrink-0 text-zinc-400 transition-transform"
        :class="expanded ? 'rotate-180' : ''"
      />
    </button>

    <div v-if="expanded" class="space-y-2 border-t border-dashed border-slate-300 px-3 py-3">
      <div
        v-for="(item, i) in items"
        :key="i"
        class="overflow-hidden rounded-lg border border-slate-200 bg-white"
      >
        <div class="flex items-center gap-2 border-b border-slate-100 bg-slate-50 px-2.5 py-1.5">
          <span
            class="rounded px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide"
            :class="roleBadge[item.Role] ?? roleBadge.system"
          >
            {{ item.Role }}
          </span>
          <span v-if="toolNames(item).length" class="truncate text-[11px] text-zinc-500">
            {{ toolNames(item).join(', ') }}
          </span>
        </div>
        <pre class="max-h-64 overflow-auto whitespace-pre-wrap break-words px-2.5 py-2 font-mono text-[11px] leading-4 text-zinc-700">{{ prettyContent(item) }}</pre>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, computed } from 'vue'
import { Wrench, ChevronDown } from '@lucide/vue'

const props = defineProps({
  items: { type: Array, required: true } // grouped system / tool / assistant(tool-calls) messages
})

const expanded = ref(false)

const roleBadge = {
  system: 'bg-slate-200 text-slate-600',
  tool: 'bg-emerald-100 text-emerald-700',
  assistant: 'bg-indigo-100 text-indigo-700'
}

const badges = computed(() => {
  const names = [...new Set(props.items.flatMap((m) => toolNames(m)))]
  const out = [`${props.items.length} step${props.items.length === 1 ? '' : 's'}`]
  if (names.length) out.push(names.slice(0, 3).join(' · '))
  return out
})

function toolNames(message) {
  if (!message.ToolCallsJson) return []
  try {
    const parsed = JSON.parse(message.ToolCallsJson)
    const list = Array.isArray(parsed) ? parsed : parsed?.tool_calls ?? []
    return list.map((t) => t?.name ?? t?.function?.name).filter(Boolean)
  } catch {
    return []
  }
}

function prettyContent(message) {
  const text = message.Content ?? message.ToolCallsJson
  if (!text) return '(empty)'
  try {
    return JSON.stringify(JSON.parse(text), null, 2)
  } catch {
    return text
  }
}
</script>
