import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY

if (!url || !anonKey) {
  console.warn(
    'Eksik ortam değişkeni: dashboard/.env içinde VITE_SUPABASE_URL ve VITE_SUPABASE_ANON_KEY tanımlayın.',
  )
}

export const supabase = createClient(url ?? '', anonKey ?? '')

export type SensorRow = {
  id: string
  name: string
  value: string | number | null
  created_at: string
}
