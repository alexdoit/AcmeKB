<template>
  <div :class="isUser ? 'flex justify-end' : 'flex justify-start'">
    <!-- User message -->
    <div
      v-if="isUser"
      class="max-w-[85%] whitespace-pre-wrap break-words rounded-xl rounded-br-sm bg-indigo-600 px-3.5 py-2.5 text-sm text-white shadow-sm"
    >
      {{ message.Content }}
    </div>

    <!-- Assistant message: sanitized markdown -->
    <div
      v-else
      class="max-w-[92%] rounded-xl rounded-bl-sm border border-slate-200 bg-white px-4 py-3 shadow-sm md:max-w-[80%]"
    >
      <div v-if="rendered" class="md-content" v-html="rendered" />
      <p v-else class="whitespace-pre-wrap text-sm text-zinc-600">{{ message.Content }}</p>
    </div>
  </div>
</template>

<script setup>
import { computed } from 'vue'
import { marked } from 'marked'
import DOMPurify from 'dompurify'

const props = defineProps({ message: { type: Object, required: true } })

const isUser = computed(() => props.message.Role === 'user')

const rendered = computed(() => {
  if (isUser.value || !props.message.Content) return ''
  return DOMPurify.sanitize(marked.parse(String(props.message.Content)))
})
</script>
