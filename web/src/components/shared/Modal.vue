<template>
  <Teleport to="body">
    <div v-if="open" class="fixed inset-0 z-50 flex items-end justify-center sm:items-center sm:p-4">
      <div
        class="absolute inset-0 bg-zinc-900/40 backdrop-blur-[2px]"
        @click="$emit('close')"
      />
      <div
        class="relative flex max-h-[92dvh] w-full flex-col overflow-hidden rounded-t-2xl bg-white shadow-xl sm:max-w-3xl sm:rounded-xl"
        role="dialog"
        aria-modal="true"
      >
        <!-- Mobile grabber handle -->
        <div class="flex justify-center pt-2 sm:hidden">
          <div class="h-1 w-10 rounded-full bg-slate-300" />
        </div>

        <div class="flex items-center justify-between gap-4 border-b border-slate-200 px-4 py-3 sm:px-6 sm:py-4">
          <h3 class="text-sm font-semibold text-zinc-900 sm:text-base">{{ title }}</h3>
          <button
            class="rounded-lg p-1.5 text-zinc-400 transition hover:bg-slate-100 hover:text-zinc-600 active:bg-slate-200"
            aria-label="Close"
            @click="$emit('close')"
          >
            <X :size="18" />
          </button>
        </div>

        <div class="min-h-0 overflow-y-auto px-4 py-4 sm:px-6 sm:py-5">
          <slot />
        </div>

        <slot name="footer" />
      </div>
    </div>
  </Teleport>
</template>

<script setup>
import { watch, onBeforeUnmount } from 'vue'
import { X } from '@lucide/vue'

const props = defineProps({
  open: { type: Boolean, default: false },
  title: { type: String, default: '' }
})

defineEmits(['close'])

// Lock body scroll while the modal is open.
watch(
  () => props.open,
  (isOpen) => {
    document.body.style.overflow = isOpen ? 'hidden' : ''
  },
  { immediate: true }
)

onBeforeUnmount(() => {
  document.body.style.overflow = ''
})
</script>
