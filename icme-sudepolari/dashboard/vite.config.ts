import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// GitHub Pages: proje sitesi https://kullanici.github.io/REPO_ADI/ → CI'da VITE_BASE=/REPO_ADI/
// Yerelde: VITE_BASE belirtmeyin (varsayılan '/')
export default defineConfig({
  plugins: [react()],
  base: process.env.VITE_BASE ?? '/',
})
