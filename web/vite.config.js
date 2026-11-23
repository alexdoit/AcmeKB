import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

// Dev server: Vite proxies /api to the local Data API builder instance so the
// client stays same-origin. This is what lets a phone on the LAN open the app
// at http://<PC-LAN-IP>:5173 without resolving `localhost` itself.
export default defineConfig({
  plugins: [vue()],
  server: {
    host: true,
    port: 5173,
    proxy: {
      '/api': {
        target: 'http://localhost:5000',
        changeOrigin: true
      }
    }
  }
})
