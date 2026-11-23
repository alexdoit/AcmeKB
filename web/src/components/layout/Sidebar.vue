<template>
  <!-- Mobile backdrop -->
  <div v-if="open" class="fixed inset-0 z-30 bg-zinc-900/40 md:hidden" @click="$emit('close')" />

  <aside
    :class="[
      'z-40 flex h-full w-72 shrink-0 flex-col border-r border-slate-200 bg-white',
      'fixed inset-y-0 left-0 transition-transform duration-200 md:static md:translate-x-0',
      open ? 'translate-x-0' : '-translate-x-full md:translate-x-0'
    ]"
  >
    <!-- Brand -->
    <div class="flex items-center gap-2.5 px-4 pb-4 pt-4">
      <div class="flex h-9 w-9 items-center justify-center rounded-xl bg-indigo-600 text-white shadow-sm">
        <Sparkles :size="18" />
      </div>
      <div>
        <div class="text-sm font-semibold tracking-tight text-zinc-900">Acme KB</div>
        <div class="text-[11px] text-zinc-500">Acme Helpdesk knowledge base</div>
      </div>
    </div>

    <!-- New chat -->
    <div class="px-4">
      <button
        class="flex w-full items-center justify-center gap-2 rounded-lg bg-indigo-600 px-3 py-2 text-sm font-medium text-white transition hover:bg-indigo-700 active:bg-indigo-800"
        @click="onNewChat"
      >
        <Plus :size="16" />
        New chat
      </button>
    </div>

    <!-- Navigation -->
    <nav class="mt-4 space-y-1 px-4">
      <router-link
        v-for="item in navItems"
        :key="item.to"
        :to="item.to"
        class="flex items-center gap-2.5 rounded-lg px-3 py-2 text-sm font-medium transition active:bg-slate-100"
        :class="
          isRoute(item.to)
            ? 'bg-indigo-50 text-indigo-700'
            : 'text-zinc-600 hover:bg-slate-100 hover:text-zinc-900'
        "
      >
        <component :is="item.icon" :size="17" />
        {{ item.label }}
      </router-link>
    </nav>

    <!-- Live sessions -->
    <div class="mt-5 flex min-h-0 flex-1 flex-col">
      <div class="flex items-center justify-between px-4 pb-2">
        <span class="text-[11px] font-semibold uppercase tracking-wider text-zinc-400">Sessions</span>
        <span v-if="sessions.length" class="text-[11px] text-zinc-400">{{ sessions.length }}</span>
      </div>

      <div class="min-h-0 flex-1 space-y-0.5 overflow-y-auto px-2 pb-3">
        <div v-if="!sessions.length" class="px-2 py-1 text-xs text-zinc-400">No sessions yet</div>

        <div v-for="session in sessions" :key="session.SessionID" class="group relative">
          <button
            class="w-full rounded-lg px-3 py-2 pr-9 text-left transition active:bg-slate-100"
            :class="isActive(session) ? 'bg-indigo-50' : 'hover:bg-slate-100'"
            @click="onSelect(session)"
          >
            <span
              class="block truncate text-[13px]"
              :class="isActive(session) ? 'font-medium text-indigo-700' : 'text-zinc-700'"
            >
              {{ session.Title || 'Untitled' }}
            </span>
            <span class="block truncate text-[11px] text-zinc-400">
              {{ formatDateTime(session.CreatedAt) }}
            </span>
          </button>
          <!-- Delete: hover on desktop, always visible on touch -->
          <button
            class="absolute right-1.5 top-1/2 -translate-y-1/2 rounded-md p-1.5 text-zinc-400 transition hover:bg-rose-50 hover:text-rose-600 active:bg-rose-100 md:opacity-0 md:group-hover:opacity-100"
            title="Delete session"
            @click="confirmDelete(session)"
          >
            <Trash2 :size="14" />
          </button>
        </div>
      </div>
    </div>

    <div class="border-t border-slate-200 px-4 py-3">
      <div class="text-[11px] leading-4 text-zinc-400">DAB: localhost:5000 · Ollama skill engine</div>
    </div>

    <!-- Delete confirmation -->
    <Modal :open="Boolean(pendingDelete)" title="Delete session?" @close="pendingDelete = null">
      <p class="text-sm text-zinc-600">
        Session “{{ pendingDelete?.Title || 'Untitled' }}” and all its messages will be deleted
        permanently.
      </p>
      <div class="mt-5 flex justify-end gap-2">
        <button
          class="rounded-lg border border-slate-300 px-3.5 py-2 text-sm font-medium text-zinc-700 transition hover:bg-slate-50 active:bg-slate-100"
          @click="pendingDelete = null"
        >
          Cancel
        </button>
        <button
          class="rounded-lg bg-rose-600 px-3.5 py-2 text-sm font-medium text-white transition hover:bg-rose-700 active:bg-rose-800 disabled:opacity-60"
          :disabled="deleting"
          @click="onDelete"
        >
          {{ deleting ? 'Deleting…' : 'Delete' }}
        </button>
      </div>
    </Modal>
  </aside>
</template>

<script setup>
import { ref, computed } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { Sparkles, Plus, MessagesSquare, BookOpen, Trash2 } from '@lucide/vue'
import { useChatStore } from '../../stores/chatStore'
import Modal from '../shared/Modal.vue'

const props = defineProps({ open: { type: Boolean, default: false } })
const emit = defineEmits(['close'])

const route = useRoute()
const router = useRouter()
const chat = useChatStore()

const navItems = [
  { to: '/chat', label: 'AI assistant', icon: MessagesSquare },
  { to: '/library', label: 'Knowledge base', icon: BookOpen }
]

const sessions = computed(() => chat.sessions)
const pendingDelete = ref(null)
const deleting = ref(false)

const dateFmt = new Intl.DateTimeFormat('en-GB', {
  day: '2-digit',
  month: 'short',
  hour: '2-digit',
  minute: '2-digit'
})

function formatDateTime(iso) {
  if (!iso) return ''
  try {
    return dateFmt.format(new Date(iso))
  } catch {
    return ''
  }
}

function isRoute(to) {
  return route.path.startsWith(to)
}

function isActive(session) {
  return chat.activeSession?.SessionID === session.SessionID
}

function closeDrawer() {
  emit('close')
}

function onNewChat() {
  chat.startNewChat()
  router.push('/chat')
  closeDrawer()
}

function onSelect(session) {
  chat.selectSession(session)
  router.push('/chat')
  closeDrawer()
}

function confirmDelete(session) {
  pendingDelete.value = session
}

async function onDelete() {
  if (!pendingDelete.value) return
  deleting.value = true
  try {
    await chat.deleteSession(pendingDelete.value)
    pendingDelete.value = null
  } catch (e) {
    window.alert(`Could not delete the session: ${e.message}`)
  } finally {
    deleting.value = false
  }
}
</script>
