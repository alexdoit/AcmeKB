<template>
  <div class="border-t border-slate-200 bg-white px-3 pt-2.5 sm:px-4">
    <!-- Safe-area bottom padding for notched phones -->
    <div class="pb-[max(0.75rem,env(safe-area-inset-bottom))]">
      <div class="flex items-end gap-2 rounded-xl border border-slate-200 bg-slate-50 p-2 transition focus-within:border-indigo-400 focus-within:ring-2 focus-within:ring-indigo-100">
        <textarea
          ref="textareaRef"
          v-model="text"
          rows="1"
          class="max-h-40 min-h-[24px] flex-1 resize-none bg-transparent px-1.5 py-1 text-sm text-zinc-800 outline-none placeholder:text-zinc-400"
          :placeholder="placeholder"
          :disabled="disabled"
          @keydown.enter.exact.prevent="submit"
          @input="autoResize"
        />
        <button
          class="flex h-9 w-9 shrink-0 items-center justify-center rounded-lg bg-indigo-600 text-white transition hover:bg-indigo-700 active:bg-indigo-800 disabled:cursor-not-allowed disabled:opacity-50"
          :disabled="disabled || !text.trim()"
          title="Send (Enter)"
          @click="submit"
        >
          <Loader2 v-if="disabled" :size="17" class="animate-spin" />
          <Send v-else :size="16" />
        </button>
      </div>
      <div class="mt-1.5 hidden text-[11px] text-zinc-400 sm:block">
        Enter to send · Shift+Enter for a new line
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, nextTick } from 'vue'
import { Send, Loader2 } from '@lucide/vue'

const props = defineProps({
  disabled: { type: Boolean, default: false },
  placeholder: { type: String, default: 'Ask the knowledge base…' }
})

const emit = defineEmits(['send'])

const text = ref('')
const textareaRef = ref(null)

function autoResize() {
  const el = textareaRef.value
  if (!el) return
  el.style.height = 'auto'
  el.style.height = `${Math.min(el.scrollHeight, 160)}px`
}

function submit() {
  const value = text.value.trim()
  if (!value || props.disabled) return
  emit('send', value)
  text.value = ''
  nextTick(() => {
    if (textareaRef.value) textareaRef.value.style.height = 'auto'
  })
}
</script>
