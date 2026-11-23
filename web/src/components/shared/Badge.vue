<template>
  <span
    :class="[
      'inline-flex items-center whitespace-nowrap rounded-full px-2.5 py-0.5 text-xs font-medium',
      variants[variant] ?? variants.slate
    ]"
  >
    {{ label }}
  </span>
</template>

<script setup>
const variants = {
  indigo: 'bg-indigo-50 text-indigo-700 ring-1 ring-inset ring-indigo-200',
  green: 'bg-emerald-50 text-emerald-700 ring-1 ring-inset ring-emerald-200',
  amber: 'bg-amber-50 text-amber-700 ring-1 ring-inset ring-amber-200',
  rose: 'bg-rose-50 text-rose-700 ring-1 ring-inset ring-rose-200',
  slate: 'bg-slate-100 text-slate-600 ring-1 ring-inset ring-slate-200'
}

defineProps({
  label: { type: String, default: '' },
  variant: { type: String, default: 'slate' }
})
</script>
