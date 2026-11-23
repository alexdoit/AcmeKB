<template>
  <div class="flex h-[100dvh] flex-col bg-slate-50 md:flex-row">
    <!-- Mobile top bar: hamburger + brand + current section -->
    <header class="flex items-center justify-between border-b border-slate-200 bg-white px-4 py-2.5 md:hidden">
      <button
        class="rounded-lg p-2 text-zinc-600 transition active:bg-slate-100"
        aria-label="Open menu"
        @click="sidebarOpen = true"
      >
        <Menu :size="22" />
      </button>

      <div class="flex items-center gap-2">
        <div class="flex h-7 w-7 items-center justify-center rounded-lg bg-indigo-600 text-white">
          <Sparkles :size="15" />
        </div>
        <span class="text-sm font-semibold tracking-tight text-zinc-900">Acme KB</span>
      </div>

      <span class="max-w-[40%] truncate text-xs font-medium text-zinc-500">{{ sectionTitle }}</span>
    </header>

    <div class="flex min-h-0 flex-1">
      <Sidebar :open="sidebarOpen" @close="sidebarOpen = false" />
      <main class="min-w-0 flex-1">
        <slot />
      </main>
    </div>
  </div>
</template>

<script setup>
import { ref, computed, watch } from 'vue'
import { useRoute } from 'vue-router'
import { Menu, Sparkles } from '@lucide/vue'
import Sidebar from './Sidebar.vue'

const route = useRoute()
const sidebarOpen = ref(false)
const sectionTitle = computed(() => route.meta?.title ?? '')

// Close the mobile drawer after navigation.
watch(() => route.path, () => {
  sidebarOpen.value = false
})
</script>
