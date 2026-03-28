import { useCallback, useEffect, useMemo, useState, type FormEvent } from 'react'
import type { Session } from '@supabase/supabase-js'
import { supabase, type SensorRow } from './lib/supabaseClient'
import './App.css'

const TANK_ORDER = ['YICME', 'GEBAN', 'TEPETOKI', 'TOKI', 'AICME'] as const

function parseLevel(v: string | number | null): number {
  if (v === null || v === undefined) return 0
  const n = typeof v === 'number' ? v : Number(String(v).trim())
  return Number.isFinite(n) ? Math.min(100, Math.max(0, n)) : 0
}

function latestByName(rows: SensorRow[]): Map<string, SensorRow> {
  const m = new Map<string, SensorRow>()
  for (const r of rows) {
    const prev = m.get(r.name)
    if (!prev || new Date(r.created_at) > new Date(prev.created_at)) {
      m.set(r.name, r)
    }
  }
  return m
}

export default function App() {
  const [session, setSession] = useState<Session | null>(null)
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [authError, setAuthError] = useState<string | null>(null)
  const [loadingAuth, setLoadingAuth] = useState(true)

  const [rows, setRows] = useState<SensorRow[]>([])
  const [loadError, setLoadError] = useState<string | null>(null)
  const [loadingData, setLoadingData] = useState(false)

  useEffect(() => {
    supabase.auth.getSession().then(({ data: { session: s } }) => {
      setSession(s)
      setLoadingAuth(false)
    })
    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange((_event, s) => setSession(s))
    return () => subscription.unsubscribe()
  }, [])

  const fetchRows = useCallback(async () => {
    setLoadError(null)
    setLoadingData(true)
    const { data, error } = await supabase
      .from('sensor_data')
      .select('id,name,value,created_at')
      .order('created_at', { ascending: false })
      .limit(400)

    setLoadingData(false)
    if (error) {
      setLoadError(error.message)
      return
    }
    setRows((data as SensorRow[]) ?? [])
  }, [])

  useEffect(() => {
    if (session) void fetchRows()
    else setRows([])
  }, [session, fetchRows])

  const latest = useMemo(() => latestByName(rows), [rows])

  const orderedTanks = useMemo(() => {
    const seen = new Set<string>()
    const out: { name: string; row: SensorRow | undefined }[] = []
    for (const name of TANK_ORDER) {
      seen.add(name)
      out.push({ name, row: latest.get(name) })
    }
    for (const name of latest.keys()) {
      if (!seen.has(name)) out.push({ name, row: latest.get(name) })
    }
    return out
  }, [latest])

  async function handleSignIn(e: FormEvent) {
    e.preventDefault()
    setAuthError(null)
    const { error } = await supabase.auth.signInWithPassword({ email, password })
    if (error) setAuthError(error.message)
  }

  async function handleSignOut() {
    await supabase.auth.signOut()
  }

  if (loadingAuth) {
    return (
      <div className="shell">
        <p className="muted">Oturum kontrol ediliyor…</p>
      </div>
    )
  }

  if (!session) {
    return (
      <div className="shell">
        <header className="page-head">
          <h1>İçme suyu depoları</h1>
          <p className="muted">Supabase hesabınızla giriş yapın.</p>
        </header>
        <form className="card login-card" onSubmit={handleSignIn}>
          <label>
            E-posta
            <input
              type="email"
              autoComplete="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              required
            />
          </label>
          <label>
            Şifre
            <input
              type="password"
              autoComplete="current-password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              required
            />
          </label>
          {authError ? <p className="error">{authError}</p> : null}
          <button type="submit">Giriş</button>
        </form>
      </div>
    )
  }

  return (
    <div className="shell">
      <header className="page-head dash-head">
        <div>
          <h1>Depo seviyeleri</h1>
          <p className="muted">
            Son güncelleme: oturum açık kullanıcı için canlı veri (yenile ile tekrar çekilir).
          </p>
        </div>
        <div className="head-actions">
          <button type="button" className="secondary" onClick={() => void fetchRows()} disabled={loadingData}>
            {loadingData ? 'Yükleniyor…' : 'Yenile'}
          </button>
          <button type="button" onClick={() => void handleSignOut()}>
            Çıkış
          </button>
        </div>
      </header>

      {loadError ? <p className="error banner">{loadError}</p> : null}

      <section className="grid-tanks">
        {orderedTanks.map(({ name, row }) => {
          const pct = row ? parseLevel(row.value) : null
          const time = row
            ? new Date(row.created_at).toLocaleString('tr-TR', {
                dateStyle: 'short',
                timeStyle: 'medium',
              })
            : '—'
          return (
            <article key={name} className="card tank-card">
              <h2>{name}</h2>
              <div className="level-num">{pct !== null ? `${pct}%` : 'Veri yok'}</div>
              <div className="bar-track" aria-hidden>
                <div className="bar-fill" style={{ width: pct !== null ? `${pct}%` : '0%' }} />
              </div>
              <p className="muted small">{time}</p>
            </article>
          )
        })}
      </section>

      <section className="card table-card">
        <h2>Son kayıtlar</h2>
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>Zaman</th>
                <th>Depo</th>
                <th>Seviye</th>
              </tr>
            </thead>
            <tbody>
              {rows.slice(0, 40).map((r) => (
                <tr key={r.id}>
                  <td>
                    {new Date(r.created_at).toLocaleString('tr-TR', {
                      dateStyle: 'short',
                      timeStyle: 'medium',
                    })}
                  </td>
                  <td>{r.name}</td>
                  <td>{parseLevel(r.value)}%</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>
    </div>
  )
}
