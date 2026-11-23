<template>
  <div class="flex flex-col items-center justify-center rounded-xl bg-white/60 px-6 py-12 text-center">
    <div class="flex h-12 w-12 items-center justify-center rounded-2xl bg-slate-100">
      <component :is="icon" :size="22" class="text-zinc-400" />
    </div>
    <p class="mt-3 text-sm font-medium text-zinc-600">{{ title }}</p>
    <p v-if="hint" class="mt-1 max-w-sm text-xs leading-4 text-zinc-400">{{ hint }}</p>
  </div>
</template>

<script setup>
import { Inbox } from '@lucide/vue'

defineProps({
  title: { type: String, default: 'Nothing found' },
  hint: { type: String, default: '' },
  // Lucide icons are functional components (functions): a plain default would be
  // called by Vue as a factory, so wrap it.
  icon: { type: [Object, Function], default: () => Inbox }
})
</script>
