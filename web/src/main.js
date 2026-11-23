import { createApp } from 'vue'
import { createPinia } from 'pinia'
import { marked } from 'marked'
import App from './App.vue'
import router from './router'
import './assets/main.css'

marked.setOptions({ gfm: true, breaks: true })

createApp(App).use(createPinia()).use(router).mount('#app')
