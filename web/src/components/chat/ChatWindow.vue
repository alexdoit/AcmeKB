<template>
  <div class="flex h-full flex-col">
    <!-- Header -->
    <header class="flex items-center justify-between gap-3 border-b border-slate-200 bg-white px-4 py-3 sm:px-6">
      <div class="min-w-0">
        <h1 class="truncate text-sm font-semibold text-zinc-900 sm:text-base">
          {{ activeTitle }}
        </h1>
        <p class="text-[11px] text-zinc-400">
          {{ isSending ? 'The model is working… (can take up to 3 minutes)' : 'Ollama skill engine · gemma4:e4b' }}
        </p>
      </div>
      <div class="flex shrink-0 items-center gap-1.5 rounded-full bg-indigo-50 px-2.5 py-1 ring-1 ring-inset ring-indigo-200">
        <Cpu :size="13" class="text-indigo-600" />
        <span class="text-[11px] font-medium text-indigo-700 sm:pr-0.5">
          <span class="hidden sm:inline">Skill engine</span>
          <span class="sm:hidden">AI</span>
        </span>
      </div>
    </header>

    <!-- Messages -->
    <div ref="scrollRef" class="min-h-0 flex-1 overflow-y-auto px-3 py-4 sm:px-6">
      <!-- Empty state -->
      <div v-if="!blocks.length && !isSending" class="mx-auto flex h-full max-w-xl flex-col items-center justify-center text-center">
        <div class="flex h-14 w-14 items-center justify-center rounded-2xl bg-indigo-50 ring-1 ring-inset ring-indigo-100">
          <Bot :size="26" class="text-indigo-600" />
        </div>
        <h2 class="mt-4 text-base font-semibold text-zinc-900">Ask anything about Acme Helpdesk</h2>
        <p class="mt-1.5 text-sm leading-5 text-zinc-500">
          The model searches release notes, helpdesk tickets and technical documentation.
        </p>
        <div class="mt-5 grid w-full gap-2">
          <button
            v-for="suggestion in suggestions"
            :key="suggestion"
            class="rounded-xl border border-slate-200 bg-white px-3.5 py-2.5 text-left text-[13px] text-zinc-600 shadow-sm transition hover:border-indigo-200 hover:bg-indigo-50/40 hover:text-indigo-700 active:bg-indigo-50"
            @click="onSuggestion(suggestion)"
          >
            {{ suggestion }}
          </button>
        </div>
      </div>

      <!-- Message stream -->
      <div v-else class="mx-auto flex max-w-3xl flex-col gap-3">
        <template v-for="(block, i) in blocks" :key="i">
          <InternalTraceViewer v-if="block.type === 'trace'" :items="block.items" />
          <MessageBubble v-else :message="block.message" />
        </template>

        <!-- Waiting indicator -->
        <div v-if="isSending" class="flex items-center gap-2 px-1 py-1 text-zinc-400">
          <span class="flex gap-1">
            <span class="h-1.5 w-1.5 animate-bounce rounded-full bg-indigo-400 [animation-delay:0ms]" />
            <span class="h-1.5 w-1.5 animate-bounce rounded-full bg-indigo-400 [animation-delay:120ms]" />
            <span class="h-1.5 w-1.5 animate-bounce rounded-full bg-indigo-400 [animation-delay:240ms]" />
          </span>
          <span class="text-xs">working…</span>
        </div>

        <div v-if="store.error" class="rounded-lg border border-rose-200 bg-rose-50 px-3 py-2 text-xs text-rose-700">
          {{ store.error }}
        </div>
      </div>
    </div>

    <!-- Input -->
    <PromptInput class="shrink-0" :disabled="isSending" @send="onSend" />
  </div>
</template>

<script setup>
import { ref, computed, watch, nextTick, onMounted } from 'vue'
import { Bot, Cpu } from '@lucide/vue'
import { useChatStore } from '../../stores/chatStore'
import MessageBubble from './MessageBubble.vue'
import InternalTraceViewer from './InternalTraceViewer.vue'
import PromptInput from './PromptInput.vue'

const store = useChatStore()
const scrollRef = ref(null)

onMounted(() => {
  if (!store.sessions.length) store.fetchSessions()
})

const suggestions = [
  'What changed in Acme Helpdesk 4.2.0?',
  'Find tickets about the SLA Engine module',
  'Why do notification emails land in spam?',
  'Which releases came out in the last 3 months?'
]

const activeTitle = computed(() =>
  store.activeSession?.Title || 'New chat'
)

// Internal dialog (system / tool / assistant tool-calls) is collapsed into
// grouped trace blocks; visible messages stay as bubbles.
const blocks = computed(() => {
  const isTrace = (m) =>
    m.Role === 'system' || m.Role === 'tool' || (m.Role === 'assistant' && m.ToolCallsJson)

  const out = []
  let trace = []
  for (const message of store.messages) {
    if (isTrace(message)) {
      trace.push(message)
      continue
    }
    if (trace.length) {
      out.push({ type: 'trace', items: trace })
      trace = []
    }
    out.push({ type: 'message', message })
  }
  if (trace.length) out.push({ type: 'trace', items: trace })
  return out
})

function scrollToBottom() {
  nextTick(() => {
    const el = scrollRef.value
    if (el) el.scrollTop = el.scrollHeight
  })
}

watch(() => store.messages.length, scrollToBottom)
watch(() => store.isSending, scrollToBottom)

function onSend(text) {
  store.sendPrompt(text)
}

function onSuggestion(text) {
  store.sendPrompt(text)
}
</script>
