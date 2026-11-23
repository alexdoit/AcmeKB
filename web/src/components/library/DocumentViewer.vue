<template>
  <Modal :open="Boolean(chunk)" :title="mode === 'edit' ? 'Edit chunk' : chunk?.Title" @close="$emit('close')">
    <template v-if="chunk">
      <!-- Breadcrumbs -->
      <div v-if="chunk.Breadcrumbs" class="mb-3 flex flex-wrap items-center gap-1 text-[11px] text-zinc-400">
        <template v-for="(part, i) in breadcrumbParts" :key="i">
          <ChevronRight v-if="i > 0" :size="11" class="text-zinc-300" />
          <span :class="i === breadcrumbParts.length - 1 ? 'text-zinc-500' : ''">{{ part }}</span>
        </template>
      </div>

      <!-- Title (edit mode keeps the title, content fields below) -->
      <h2 v-if="mode === 'view'" class="text-base font-semibold leading-6 text-zinc-900 sm:text-lg">
        {{ chunk.Title }}
      </h2>

      <!-- Metadata -->
      <div class="mt-3 flex flex-wrap items-center gap-1.5">
        <Badge :label="chunk.DocType" variant="indigo" />
        <Badge :label="chunk.AppName" variant="slate" />
        <Badge :label="chunk.ModuleName" variant="slate" />
        <Badge v-if="chunk.AppVersion" :label="`v${chunk.AppVersion}`" variant="amber" />
        <Badge v-if="chunk.EventDate" :label="formatDate(chunk.EventDate)" variant="green" />
      </div>

      <!-- View mode: rendered content -->
      <div v-if="mode === 'view'">
        <div class="mt-4 rounded-xl border border-slate-200 bg-slate-50/60 px-4 py-3.5">
          <div v-if="renderedContent" class="md-content" v-html="renderedContent" />
          <p v-else class="whitespace-pre-wrap text-sm text-zinc-500">
            {{ chunk.MainContent || 'No content' }}
          </p>
        </div>

        <div class="mt-4 flex flex-wrap items-center justify-between gap-2">
          <div class="text-[11px] text-zinc-400">
            ChunkID: {{ chunk.ChunkID }} · DocumentID: {{ chunk.DocumentID }}
          </div>
          <div class="flex gap-2">
            <button
              class="flex items-center gap-1.5 rounded-lg border border-slate-300 px-3 py-1.5 text-xs font-medium text-zinc-700 transition hover:bg-slate-50 active:bg-slate-100"
              @click="copyContent"
            >
              <Check v-if="copied" :size="14" class="text-emerald-600" />
              <Copy v-else :size="14" />
              {{ copied ? 'Copied' : 'Copy' }}
            </button>
            <button
              class="flex items-center gap-1.5 rounded-lg bg-indigo-600 px-3 py-1.5 text-xs font-medium text-white transition hover:bg-indigo-700 active:bg-indigo-800"
              @click="startEdit"
            >
              <Pencil :size="14" />
              Edit
            </button>
          </div>
        </div>
      </div>

      <!-- Edit mode: SearchContext + MainContent -->
      <div v-else class="mt-4 space-y-4">
        <div>
          <label class="mb-1.5 block text-xs font-semibold text-zinc-600">SearchContext (search context)</label>
          <textarea
            v-model="editForm.searchContext"
            rows="3"
            class="w-full resize-y rounded-lg border border-slate-200 bg-white px-3 py-2 text-xs leading-5 text-zinc-700 shadow-sm outline-none transition focus:border-indigo-400 focus:ring-2 focus:ring-indigo-100"
          />
        </div>
        <div>
          <label class="mb-1.5 block text-xs font-semibold text-zinc-600">MainContent (content)</label>
          <textarea
            v-model="editForm.mainContent"
            rows="14"
            class="w-full resize-y rounded-lg border border-slate-200 bg-white px-3 py-2 font-mono text-xs leading-5 text-zinc-800 shadow-sm outline-none transition focus:border-indigo-400 focus:ring-2 focus:ring-indigo-100"
          />
        </div>

        <div class="flex items-center justify-end gap-2">
          <span v-if="saved" class="mr-auto flex items-center gap-1 text-xs font-medium text-emerald-600">
            <Check :size="14" /> Saved
          </span>
          <span v-if="saveError" class="mr-auto text-xs text-rose-600">{{ saveError }}</span>
          <button
            class="rounded-lg border border-slate-300 px-3.5 py-2 text-sm font-medium text-zinc-700 transition hover:bg-slate-50 active:bg-slate-100"
            :disabled="saving"
            @click="mode = 'view'"
          >
            Cancel
          </button>
          <button
            class="rounded-lg bg-indigo-600 px-3.5 py-2 text-sm font-medium text-white transition hover:bg-indigo-700 active:bg-indigo-800 disabled:opacity-60"
            :disabled="saving"
            @click="save"
          >
            {{ saving ? 'Saving…' : 'Save' }}
          </button>
        </div>
      </div>
    </template>
  </Modal>
</template>

<script setup>
import { ref, computed, watch } from 'vue'
import { marked } from 'marked'
import DOMPurify from 'dompurify'
import { Copy, Check, Pencil, ChevronRight } from '@lucide/vue'
import { useKnowledgeStore } from '../../stores/knowledgeStore'
import Modal from '../shared/Modal.vue'
import Badge from '../shared/Badge.vue'

const props = defineProps({ chunk: { type: Object, default: null } })
const emit = defineEmits(['close'])

const store = useKnowledgeStore()

const mode = ref('view')
const copied = ref(false)
const saved = ref(false)
const saving = ref(false)
const saveError = ref('')
const editForm = ref({ searchContext: '', mainContent: '' })

// Reset form state whenever a new chunk is opened.
watch(
  () => props.chunk,
  (chunk) => {
    mode.value = 'view'
    copied.value = false
    saved.value = false
    saveError.value = ''
    editForm.value = {
      searchContext: chunk?.SearchContext ?? '',
      mainContent: chunk?.MainContent ?? ''
    }
  },
  { immediate: true }
)

const renderedContent = computed(() => {
  if (!props.chunk?.MainContent) return ''
  return DOMPurify.sanitize(marked.parse(String(props.chunk.MainContent)))
})

const breadcrumbParts = computed(() =>
  (props.chunk?.Breadcrumbs || '')
    .split(/[›>\/]/)
    .map((part) => part.trim())
    .filter(Boolean)
)

const dateFmt = new Intl.DateTimeFormat('en-GB', { day: '2-digit', month: '2-digit', year: 'numeric' })

function formatDate(iso) {
  try {
    return dateFmt.format(new Date(iso))
  } catch {
    return iso
  }
}

async function copyContent() {
  try {
    await navigator.clipboard.writeText(props.chunk.MainContent || '')
    copied.value = true
    setTimeout(() => (copied.value = false), 2000)
  } catch {
    /* clipboard unavailable (e.g. non-secure context) */
  }
}

function startEdit() {
  editForm.value = {
    searchContext: props.chunk.SearchContext ?? '',
    mainContent: props.chunk.MainContent ?? ''
  }
  saved.value = false
  saveError.value = ''
  mode.value = 'edit'
}

async function save() {
  saving.value = true
  saveError.value = ''
  try {
    await store.saveChunk(props.chunk.ChunkID, {
      SearchContext: editForm.value.searchContext,
      MainContent: editForm.value.mainContent
    })
    saved.value = true
    setTimeout(() => (mode.value = 'view'), 600)
  } catch (e) {
    saveError.value = e.response?.data?.message || e.message
  } finally {
    saving.value = false
  }
}
</script>
