import { createRouter, createWebHistory } from 'vue-router'
import ChatView from '../views/ChatView.vue'
import LibraryView from '../views/LibraryView.vue'

const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/', redirect: '/chat' },
    {
      path: '/chat',
      name: 'chat',
      component: ChatView,
      meta: { title: 'AI assistant' }
    },
    {
      path: '/library',
      name: 'library',
      component: LibraryView,
      meta: { title: 'Knowledge base' }
    }
  ]
})

router.afterEach((to) => {
  document.title = to.meta?.title ? `${to.meta.title} — Acme KB` : 'Acme KB'
})

export default router
