// Server webapp screens — redesigned with DESIGN.md tokens.
// 7 screens: Overview, Transcript Review, Process, Harvest, Ingest, Dictionary, Settings
// All rendered at 1120×720 in a shared shell with left sidebar.

const WA_W = 1120;
const WA_H = 720;

// Sidebar nav items
const NAV = [
  { id: "overview",   label: "Overview",   icon: "M3 3h7v7H3zM14 3h7v7h-7zM3 14h7v7H3zM14 14h7v7h-7z" },
  { id: "transcript", label: "Transcript", icon: "M4 4h16v16H4zM8 8h8M8 12h6" },
  { id: "process",    label: "Process",    icon: "M12 2l3 7h7l-5.5 4.5 2 7L12 16l-6.5 4.5 2-7L2 9h7z" },
  { id: "harvest",    label: "Harvest",    icon: "M12 6v6l4 2M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20z" },
  { id: "ingest",     label: "Ingest",     icon: "M12 16V4M12 4l-4 4M12 4l4 4M4 14v4a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-4" },
  { id: "dictionary", label: "Dictionary", icon: "M4 4h4v16H4zM12 4h8M12 8h8M12 12h8M12 16h5" },
  { id: "settings",   label: "Settings",   icon: "M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06A1.65 1.65 0 0 0 15 19.4V21a2 2 0 0 1-4 0v-.09a1.65 1.65 0 0 0-1-1.51 1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.6 15H3a2 2 0 0 1 0-4h.09a1.65 1.65 0 0 0 1.51-1V9a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1.51 1H12a2 2 0 0 1 0 4h-.09Z" },
];

const waShellStyles = {
  shell: { width: WA_W, height: WA_H, display: 'flex', background: 'var(--surface)', fontFamily: 'var(--font)', color: 'var(--text-primary)', fontSize: 15, overflow: 'hidden', position: 'relative' },
  sidebar: { width: 60, flexShrink: 0, background: 'var(--container)', borderRight: '1px solid var(--border-subdued)', display: 'flex', flexDirection: 'column', alignItems: 'center', padding: '16px 0', gap: 2 },
  logo: { fontSize: 13, fontWeight: 700, letterSpacing: '0.06em', color: 'var(--text-primary)', marginBottom: 16, fontFamily: 'var(--mono)' },
  navItem: (active) => ({ width: 48, height: 48, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 3, borderRadius: 8, cursor: 'pointer', background: active ? 'var(--surface-inset)' : 'transparent', color: active ? 'var(--text-primary)' : 'var(--text-subdued)', fontSize: 9, fontWeight: 500, letterSpacing: '0.02em', border: 0, padding: 0 }),
  main: { flex: 1, display: 'flex', flexDirection: 'column', overflow: 'hidden' },
  topBar: { height: 52, flexShrink: 0, display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '0 24px', borderBottom: '1px solid var(--border-subdued)', background: 'var(--container)' },
  pageTitle: { fontSize: 17, fontWeight: 600 },
  content: { flex: 1, overflow: 'auto', padding: '24px' },
};

const NavIcon = ({ d, size = 18 }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
    <path d={d}/>
  </svg>
);

const Shell = ({ active, title, topRight, children }) => (
  <div className="vd-frame" style={waShellStyles.shell}>
    <div style={waShellStyles.sidebar}>
      <div style={waShellStyles.logo}>DP</div>
      {NAV.map(n => (
        <button key={n.id} style={waShellStyles.navItem(n.id === active)}>
          <NavIcon d={n.icon} size={18}/>
          <span>{n.label}</span>
        </button>
      ))}
    </div>
    <div style={waShellStyles.main}>
      <div style={waShellStyles.topBar}>
        <span style={waShellStyles.pageTitle}>{title}</span>
        <span style={{display:'flex', gap:12, alignItems:'center', color:'var(--text-secondary)', fontSize:13}}>
          {topRight}
        </span>
      </div>
      <div style={waShellStyles.content}>
        {children}
      </div>
    </div>
  </div>
);

// Shared: status badge
const StatusBadge = ({ status }) => {
  const map = {
    PENDING:   { bg: 'rgba(220,104,3,0.10)', color: '#DC6803', border: 'rgba(220,104,3,0.20)' },
    SAVED:     { bg: 'rgba(16,168,97,0.10)',  color: '#10A861', border: 'rgba(16,168,97,0.20)' },
    SUBMITTED: { bg: 'rgba(21,112,239,0.08)', color: '#1570EF', border: 'rgba(21,112,239,0.20)' },
    PROCESSED: { bg: 'rgba(16,168,97,0.10)',  color: '#10A861', border: 'rgba(16,168,97,0.20)' },
    FAILED:    { bg: 'rgba(236,34,34,0.10)',  color: '#EC2222', border: 'rgba(236,34,34,0.20)' },
    PERSON:    { bg: 'rgba(16,168,97,0.10)',  color: '#10A861', border: 'rgba(16,168,97,0.20)' },
    ORGANIZATION: { bg: 'rgba(21,112,239,0.08)', color: '#1570EF', border: 'rgba(21,112,239,0.20)' },
  };
  const s = map[status] || map.PENDING;
  return (
    <span style={{
      display: 'inline-block',
      padding: '2px 8px',
      borderRadius: 9999,
      fontSize: 11,
      fontWeight: 600,
      letterSpacing: '0.04em',
      background: s.bg,
      color: s.color,
      border: `1px solid ${s.border}`,
    }}>{status}</span>
  );
};

// Shared: filter tabs
const FilterTabs = ({ items, active }) => (
  <div style={{display:'flex', gap:6}}>
    {items.map(([label, count]) => (
      <button key={label} style={{
        display:'inline-flex', alignItems:'center', gap:6,
        padding:'6px 12px', borderRadius:8,
        fontSize:13, fontWeight:500,
        background: active===label ? 'var(--text-primary)' : 'var(--container)',
        color: active===label ? 'var(--text-inverse)' : 'var(--text-secondary)',
        border: active===label ? 'none' : '1px solid var(--border-subdued)',
        cursor:'pointer',
      }}>
        {label} {count !== undefined && <span style={{opacity:0.7}}>{count}</span>}
      </button>
    ))}
  </div>
);

// Shared: table
const Th = ({ children, w, align = 'left' }) => (
  <th style={{textAlign:align, fontWeight:500, fontSize:12, letterSpacing:'0.04em', textTransform:'uppercase', color:'var(--text-subdued)', padding:'10px 12px', width:w, borderBottom:'1px solid var(--border-subdued)'}}>{children}</th>
);
const Td = ({ children, mono, muted, align = 'left' }) => (
  <td style={{textAlign:align, padding:'12px', fontSize:14, fontFamily: mono ? 'var(--mono)' : 'inherit', color: muted ? 'var(--text-subdued)' : 'var(--text-primary)', fontVariantNumeric: mono ? 'tabular-nums' : 'normal', borderBottom:'1px solid var(--border-subdued)'}}>{children}</td>
);

// ─── SCREEN 1: OVERVIEW ──────────────────
const WaOverview = () => {
  const rows = [
    { file: "diary-14.05.2025", author: "Florian Wolf", status: "PENDING", words: 476, date: "14 May 2025", day: "Wed", up: "5 days ago" },
    { file: "2026-04-30T05:17:50Z::sClose.m4a", author: "Florian Wolf", status: "PENDING", words: 3, date: "30 Apr 2026", day: "Thu", up: "3 days ago" },
    { file: "2026-04-30T05:17:50Z::s08.m4a", author: "Florian Wolf", status: "PENDING", words: 4, date: "30 Apr 2026", day: "Thu", up: "3 days ago" },
    { file: "2026-04-30T05:17:50Z::s07.m4a", author: "Florian Wolf", status: "PENDING", words: 34, date: "30 Apr 2026", day: "Thu", up: "3 days ago" },
    { file: "2026-04-30T05:17:50Z::s06.m4a", author: "Florian Wolf", status: "PENDING", words: 22, date: "30 Apr 2026", day: "Thu", up: "3 days ago" },
    { file: "2026-04-30T05:17:50Z::s05.m4a", author: "Florian Wolf", status: "PENDING", words: 34, date: "30 Apr 2026", day: "Thu", up: "3 days ago" },
    { file: "2026-04-29T18:52:10Z::sClose.m4a", author: "Florian Wolf", status: "SAVED", words: 33, date: "29 Apr 2026", day: "Wed", up: "3 days ago" },
    { file: "2026-04-29T18:52:10Z::s01.m4a", author: "Florian Wolf", status: "SAVED", words: 6, date: "29 Apr 2026", day: "Wed", up: "3 days ago" },
  ];
  return (
    <Shell active="overview" title="Overview" topRight={
      <div style={{display:'flex',alignItems:'center',gap:12}}>
        <input type="text" placeholder="Search transcripts…" style={{
          padding:'7px 12px', fontSize:13, border:'1px solid var(--border-subdued)',
          borderRadius:8, background:'var(--container)', color:'var(--text-primary)',
          fontFamily:'var(--font)', width:200,
        }}/>
      </div>
    }>
      <div style={{marginBottom:16}}>
        <div style={{fontSize:12, fontWeight:600, letterSpacing:'0.06em', textTransform:'uppercase', color:'var(--text-subdued)', marginBottom:12}}>Transcripts</div>
        <FilterTabs items={[["All",35],["Pending",26],["Saved",9],["Submitted",0],["Processed",0],["Failed",0]]} active="All"/>
      </div>
      <div className="card" style={{padding:0, overflow:'hidden'}}>
        <table style={{width:'100%', borderCollapse:'collapse'}}>
          <thead>
            <tr>
              <Th w={360}>Filename</Th>
              <Th w={100} align="center">Status</Th>
              <Th w={80} align="right">Words</Th>
              <Th w={140}>Diary Date</Th>
              <Th w={100}>Uploaded</Th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r,i) => (
              <tr key={i} style={{cursor:'pointer'}}>
                <Td>
                  <div style={{fontWeight:500, color:'var(--text-link)'}}>{r.file}</div>
                  <div style={{fontSize:12, color:'var(--text-subdued)', marginTop:2}}>{r.author}</div>
                </Td>
                <Td align="center"><StatusBadge status={r.status}/></Td>
                <Td mono align="right">{r.words}</Td>
                <Td>
                  <div>{r.date}</div>
                  <div style={{fontSize:11, color:'var(--text-subdued)'}}>{r.day}</div>
                </Td>
                <Td muted>{r.up}</Td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <div style={{display:'flex', justifyContent:'space-between', alignItems:'center', marginTop:16, fontSize:13, color:'var(--text-subdued)'}}>
        <span>Showing 1–8 of 35</span>
        <div style={{display:'flex', gap:4}}>
          {[1,2,'…',4].map((p,i) => (
            <button key={i} style={{
              width:32, height:32, borderRadius:8, border: p===1 ? 'none' : '1px solid var(--border-subdued)',
              background: p===1 ? 'var(--text-primary)' : 'var(--container)',
              color: p===1 ? 'var(--text-inverse)' : 'var(--text-secondary)',
              fontSize:13, fontWeight:500, cursor:'pointer', display:'flex', alignItems:'center', justifyContent:'center',
            }}>{p}</button>
          ))}
        </div>
      </div>
    </Shell>
  );
};

// ─── SCREEN 2: TRANSCRIPT REVIEW ──────────────────
const WaTranscript = () => {
  const Entity = ({ children, kind = "pending" }) => {
    const styles = {
      confirmed: { bg: 'rgba(16,168,97,0.10)', border: 'rgba(16,168,97,0.30)', color: 'var(--text-primary)', deco: 'none' },
      pending:   { bg: 'rgba(21,112,239,0.06)', border: 'rgba(21,112,239,0.40)', color: 'var(--text-primary)', deco: 'none' },
      rejected:  { bg: 'transparent', border: 'var(--border-subdued)', color: 'var(--text-subdued)', deco: 'line-through' },
    };
    const s = styles[kind] || styles.pending;
    return <span style={{
      fontFamily:'var(--mono)', fontSize:13, padding:'2px 6px', borderRadius:4,
      background:s.bg, border:`1px ${kind==='rejected'?'dashed':'solid'} ${s.border}`,
      color:s.color, textDecoration:s.deco, cursor:'pointer',
    }}>{children}</span>;
  };

  return (
    <Shell active="transcript" title="Review: diary-14.05.2025" topRight={
      <span className="mono" style={{fontSize:12}}>2025-05-14 · Florian Wolf</span>
    }>
      {/* LLM corrections banner */}
      <div style={{
        background:'rgba(16,168,97,0.06)', border:'1px solid rgba(16,168,97,0.20)',
        borderRadius:8, padding:'10px 14px', marginBottom:16,
        display:'flex', alignItems:'center', gap:10, fontSize:13,
      }}>
        <span className="dot dot-success" style={{width:8, height:8}}/>
        <span style={{fontWeight:500}}>5 LLM corrections:</span>
        <span style={{color:'var(--text-secondary)'}}>Charakterzüge → Charakterschwächen, beursachtet → erfüllt, hochentmittelt → hochengangeirt, saat → späteztig</span>
      </div>

      {/* Stats row */}
      <div style={{display:'flex', gap:16, marginBottom:20, fontSize:12, color:'var(--text-subdued)'}}>
        <span>● 12 auto-corrected</span>
        <span style={{color:'var(--status-success)'}}>● 0 suggested</span>
        <span>● 0 new</span>
        <span>● 0 need review</span>
        <span>● 3 disfluent</span>
      </div>

      <div style={{display:'grid', gridTemplateColumns:'1fr 280px', gap:24}}>
        {/* Transcript */}
        <div>
          <div style={{fontSize:12, fontWeight:600, letterSpacing:'0.06em', textTransform:'uppercase', color:'var(--text-subdued)', marginBottom:12}}>Transcript with Entity Detection</div>
          <div style={{fontSize:15, lineHeight:1.85, color:'var(--text-primary)'}}>
            <p style={{marginBottom:14}}>
              Tag 1 bei der <Entity kind="confirmed">Enersys → Enersis</Entity>. Eindrücke. Ich habe heute die <Entity kind="confirmed">Enersys → Enersis</Entity> besucht und war um 14.30 mit <Entity kind="confirmed">Thomas → Thomas Koller</Entity> verabredet, hatte angenommen, dass ich anderthalb Stunden mit ihm sprechen werde.
            </p>
            <p style={{marginBottom:14}}>
              Er hat mir kurz ein paar Dinge gezeigt, wo er gerade steht. Ich erinnere, dass er mir sehr viele Zusagen gemacht hat. Ich zeig dir, ich werf dir mal die Strategie, das Strategiepapier über den Zaun. Ich binde dich ein.
            </p>
            <p style={{marginBottom:14}}>
              Ich habe kurz mit, jetzt zum Abschluss. <Entity kind="pending">Christian → Christian Bolger</Entity> Tiener, den Kollegen, den ich schon wenig weiß, wie er heißt, der zum Monatsende ausscheidet.
            </p>
            <p>
              Der weitere Baustein, den ich allerdings heute noch beobachtet habe, war <Entity kind="pending">Monika → Monica Breitkreutz</Entity>, die sehr viel Wert auf Transparenz, Offenheit und so weiter legt.
            </p>
          </div>
        </div>

        {/* Entity sidebar */}
        <div>
          <div style={{fontSize:12, fontWeight:600, letterSpacing:'0.06em', textTransform:'uppercase', color:'var(--text-subdued)', marginBottom:12}}>Detected Entities</div>
          <div style={{display:'flex', flexDirection:'column', gap:8}}>
            {[
              { name: "Enersis", type: "ORGANIZATION", vars: "variation: 1 Enersis", confirmed: true },
              { name: "Enersis", type: "ORGANIZATION", confirmed: false },
              { name: "Enersis", type: "ORGANIZATION", confirmed: false },
              { name: "Thomas", type: "PERSON", vars: "first name: CEO, Head of Sales", confirmed: true },
            ].map((e,i) => (
              <div key={i} className="card" style={{padding:'10px 12px', display:'flex', alignItems:'center', justifyContent:'space-between', gap:8}}>
                <div style={{display:'flex', alignItems:'center', gap:8, minWidth:0}}>
                  <span className={`dot ${e.confirmed ? 'dot-success' : 'dot-link'}`} style={{width:8, height:8}}/>
                  <span style={{fontSize:14, fontWeight:500, overflow:'hidden', textOverflow:'ellipsis', whiteSpace:'nowrap'}}>{e.name}</span>
                </div>
                <StatusBadge status={e.type}/>
              </div>
            ))}
          </div>
        </div>
      </div>

      {/* Bottom bar */}
      <div style={{
        position:'absolute', left:60, right:0, bottom:0,
        background:'var(--container)', borderTop:'1px solid var(--border-subdued)',
        padding:'12px 24px', display:'flex', justifyContent:'space-between', alignItems:'center',
      }}>
        <span style={{fontSize:13, color:'var(--text-subdued)'}}>12 corrections, 0 new entities — will be saved to dictionary</span>
        <div style={{display:'flex', gap:8}}>
          <button className="btn btn-ghost" style={{height:36, fontSize:14, color:'var(--status-destructive)'}}>Reset</button>
          <button className="btn btn-secondary" style={{height:36, fontSize:14}}>Save</button>
          <button className="btn btn-primary" style={{height:36, fontSize:14, padding:'0 16px'}}>Save & Process →</button>
        </div>
      </div>
    </Shell>
  );
};

// ─── SCREEN 3: PROCESS ──────────────────
const WaProcess = ({ state = "complete" }) => {
  const steps = [
    { id: "context",  label: "Context",  desc: "Query LightRAG for historical context", done: state==="complete" },
    { id: "summary",  label: "Summary",  desc: "Compose context via LLM", done: state==="complete" },
    { id: "analysis", label: "Analysis", desc: "Extract structured data via LLM", done: state==="complete" },
    { id: "document", label: "Document", desc: "Generate narrative via markdown", done: state==="complete" },
  ];
  return (
    <Shell active="process" title="Process: diary-14.05.2025" topRight={
      <span className="mono" style={{fontSize:12}}>Date: 2025-05-14 · Author: Florian Wolf</span>
    }>
      <div style={{display:'grid', gridTemplateColumns:'200px 1fr', gap:24, height:'100%'}}>
        {/* Pipeline steps */}
        <div>
          <div style={{display:'flex', flexDirection:'column', gap:4}}>
            {steps.map((s,i) => (
              <button key={s.id} style={{
                display:'flex', alignItems:'flex-start', gap:10, padding:'10px 12px',
                borderRadius:8, border:0, cursor:'pointer', textAlign:'left',
                background: i===steps.length-1 ? 'var(--text-link)' : 'transparent',
                color: i===steps.length-1 ? '#fff' : 'var(--text-primary)',
              }}>
                <span className={`dot ${s.done ? 'dot-success' : 'dot-subdued'}`} style={{width:8, height:8, marginTop:5, flexShrink:0}}/>
                <div>
                  <div style={{fontSize:14, fontWeight:500}}>{s.label}</div>
                  <div style={{fontSize:11, opacity:0.7, marginTop:2}}>{s.desc}</div>
                </div>
              </button>
            ))}
          </div>
          {state !== "complete" && (
            <button className="btn btn-primary btn-full" style={{marginTop:16, height:40, fontSize:14}}>Start Processing</button>
          )}
          {state === "complete" && (
            <button className="btn btn-secondary btn-full" style={{marginTop:16, height:36, fontSize:13}}>Re-process</button>
          )}

          {/* Log excerpt */}
          {state === "complete" && (
            <div style={{marginTop:16, padding:'10px 12px', background:'var(--container-inset)', borderRadius:8, fontSize:11, fontFamily:'var(--mono)', color:'var(--text-subdued)', lineHeight:1.6}}>
              <div style={{color:'var(--status-success)'}}>✓ Summary: Letzte Woche…</div>
              <div style={{color:'var(--status-success)'}}>✓ Analysis: 3 relationships</div>
              <div style={{color:'var(--status-success)'}}>✓ Document generated</div>
              <div>── processing complete ──</div>
            </div>
          )}
        </div>

        {/* Document preview */}
        <div className="card" style={{padding:'28px 32px', overflow:'auto'}}>
          <div style={{display:'flex', gap:12, marginBottom:20, borderBottom:'1px solid var(--border-subdued)', paddingBottom:12}}>
            {["Preview","Edit","Analysis JSON"].map((tab,i) => (
              <button key={tab} style={{
                fontSize:13, fontWeight:500, padding:'4px 0', border:0, cursor:'pointer',
                background:'transparent',
                color: i===0 ? 'var(--text-primary)' : 'var(--text-subdued)',
                borderBottom: i===0 ? '2px solid var(--text-primary)' : '2px solid transparent',
              }}>{tab}</button>
            ))}
          </div>

          {state === "complete" ? (
            <div style={{fontSize:15, lineHeight:1.7}}>
              <h2 style={{fontSize:20, fontWeight:600, marginBottom:4}}>CTO Tagebuch – Kalenderwoche 20, 2025</h2>
              <p style={{fontSize:13, color:'var(--text-secondary)', marginBottom:20}}>
                Eintrag vom Mittwoch, 14. Mai 2025 (Kalenderwoche 20, Q2 2025) Autor: Florian Wolf (CTO, Managing Director) bei Enersis
              </p>
              <h3 style={{fontSize:16, fontWeight:600, color:'var(--status-success)', marginBottom:8}}>Zusammenfassung</h3>
              <p style={{color:'var(--text-secondary)', marginBottom:20}}>
                Am 14. Mai 2025, während der Kalenderwoche 20 im Q2, hat Florian Wolf folgende Themen bearbeitet:
              </p>
              <h3 style={{fontSize:16, fontWeight:600, color:'var(--status-success)', marginBottom:8}}>Historischer Kontext</h3>
              <p style={{fontWeight:500, marginBottom:6}}>Letzte Woche:</p>
              <ul style={{paddingLeft:20, color:'var(--text-secondary)', fontSize:14, lineHeight:1.8, marginBottom:20}}>
                <li>Dokumentationsaufarbeitung für KW 18 geplant</li>
                <li>To-Do aus Besprechung mit Mansour offen</li>
                <li>Florian Wolf verfasst Tagebucheinträge</li>
              </ul>
              <h3 style={{fontSize:16, fontWeight:600, color:'var(--status-success)', marginBottom:8}}>Tagebucheintrag</h3>
              <p style={{color:'var(--text-secondary)', lineHeight:1.7}}>
                Tag 1 bei der Enersis. Eindrücke. Ich habe heute die Enersis besucht und war um 14.30 mit Thomas Koller verabredet, hatte angenommen, dass ich anderthalb Stunden mit ihm sprechen werde…
              </p>
            </div>
          ) : (
            <div style={{display:'flex', alignItems:'center', justifyContent:'center', height:300, color:'var(--text-subdued)', fontSize:14}}>
              No document generated yet. Click "Start Processing" to begin.
            </div>
          )}
        </div>
      </div>

      {/* Bottom bar */}
      <div style={{
        position:'absolute', left:60, right:0, bottom:0,
        background:'var(--container)', borderTop:'1px solid var(--border-subdued)',
        padding:'12px 24px', display:'flex', justifyContent:'flex-end', alignItems:'center', gap:8,
      }}>
        <button className="btn btn-secondary" style={{height:36, fontSize:14}}>Save</button>
        <button className="btn btn-primary" style={{height:36, fontSize:14, padding:'0 16px'}}>Send to LightRAG</button>
      </div>
    </Shell>
  );
};

// ─── SCREEN 4: HARVEST ──────────────────
const WaHarvest = () => {
  const entries = [
    { dur: "0.50h", desc: "Besprechung mit Thomas über die aktuelle Situation und Zukunft der Enersis" },
    { dur: "0.25h", desc: "Kurze Diskussion mit Christian Tiener zum Arbeitsende und Teambekanntmachung" },
    { dur: "0.25h", desc: "Besprechung mit Monika über Bring Your Own Device (BYOD) Richtlinien" },
  ];
  return (
    <Shell active="harvest" title="Harvest Time Tracking" topRight={
      <div style={{display:'flex', alignItems:'center', gap:12}}>
        <button style={{border:'1px solid var(--border-subdued)', borderRadius:6, background:'var(--container)', padding:'5px 8px', cursor:'pointer', color:'var(--text-secondary)', fontSize:14}}>‹</button>
        <span className="mono" style={{fontSize:13}}>14/05/2025</span>
        <button style={{border:'1px solid var(--border-subdued)', borderRadius:6, background:'var(--container)', padding:'5px 8px', cursor:'pointer', color:'var(--text-secondary)', fontSize:14}}>›</button>
        <button className="btn btn-secondary" style={{height:32, fontSize:13}}>Today</button>
      </div>
    }>
      <div style={{display:'grid', gridTemplateColumns:'300px 1fr', gap:24}}>
        {/* Left: sources */}
        <div>
          <div className="card" style={{marginBottom:12}}>
            <div style={{display:'flex', alignItems:'center', gap:8, marginBottom:6}}>
              <span style={{fontSize:14}}>📅</span>
              <span style={{fontSize:14, fontWeight:500}}>Calendar</span>
            </div>
            <div style={{fontSize:13, color:'var(--text-subdued)'}}>No events</div>
          </div>
          <div className="card">
            <div style={{display:'flex', alignItems:'center', justifyContent:'space-between', marginBottom:6}}>
              <div style={{display:'flex', alignItems:'center', gap:8}}>
                <span style={{fontSize:14}}>📓</span>
                <span style={{fontSize:14, fontWeight:500}}>Diary Transcript</span>
              </div>
              <StatusBadge status="PENDING"/>
            </div>
            <a href="#" style={{fontSize:13, color:'var(--text-link)', textDecoration:'none'}}>Open transcript in review</a>
          </div>
        </div>

        {/* Right: suggested entries */}
        <div>
          <div style={{display:'flex', justifyContent:'space-between', alignItems:'baseline', marginBottom:14}}>
            <span style={{fontSize:12, fontWeight:600, letterSpacing:'0.06em', textTransform:'uppercase', color:'var(--text-subdued)'}}>Suggested Entries</span>
            <span style={{fontSize:13, color:'var(--text-secondary)'}}>3 entries · <span className="mono" style={{fontWeight:500}}>1.00h</span></span>
          </div>

          <div style={{display:'flex', flexDirection:'column', gap:12}}>
            {entries.map((e,i) => (
              <div key={i} className="card" style={{padding:0, overflow:'hidden'}}>
                <div style={{display:'flex', justifyContent:'flex-end', alignItems:'center', padding:'10px 14px', borderBottom:'1px solid var(--border-subdued)', gap:8}}>
                  <span className="mono" style={{fontSize:14, fontWeight:600}}>{e.dur}</span>
                  <span style={{
                    fontSize:10, fontWeight:600, letterSpacing:'0.06em',
                    padding:'2px 8px', borderRadius:4,
                    background:'rgba(21,112,239,0.08)', color:'var(--text-link)',
                    border:'1px solid rgba(21,112,239,0.20)',
                  }}>DIARY+LLM</span>
                </div>
                <div style={{padding:'8px 14px'}}>
                  <select style={{width:'100%', padding:'6px 8px', fontSize:13, border:'1px solid var(--border-subdued)', borderRadius:6, background:'var(--container)', color:'var(--text-secondary)', marginBottom:6}}>
                    <option>— Select project —</option>
                  </select>
                  <select style={{width:'100%', padding:'6px 8px', fontSize:13, border:'1px solid var(--border-subdued)', borderRadius:6, background:'var(--container)', color:'var(--text-subdued)', marginBottom:8}}>
                    <option>— No tasks —</option>
                  </select>
                </div>
                <div style={{padding:'0 14px 12px', fontSize:14, color:'var(--text-secondary)', lineHeight:1.5}}>
                  {e.desc}
                </div>
              </div>
            ))}
          </div>
        </div>
      </div>
    </Shell>
  );
};

// ─── SCREEN 5: INGEST ──────────────────
const WaIngest = () => (
  <Shell active="ingest" title="Audio Ingestion" topRight={
    <span style={{fontSize:13, color:'var(--text-subdued)'}}>Upload diary audio files. The server runs ffmpeg + Whisper locally.</span>
  }>
    <div style={{maxWidth:600, margin:'0 auto', paddingTop:24}}>
      <div style={{
        border:'2px dashed var(--border-subdued)', borderRadius:12,
        padding:'48px 24px', textAlign:'center',
        background:'var(--container)',
      }}>
        <div style={{fontSize:32, marginBottom:12, opacity:0.3}}>🎙</div>
        <div style={{fontSize:15, fontWeight:500, marginBottom:6}}>Drop audio files here or click to browse</div>
        <div style={{fontSize:13, color:'var(--text-subdued)'}}>Accepts .mp3 and .m4a files · Multiple files supported</div>
      </div>

      <div style={{marginTop:32}}>
        <div style={{fontSize:14, fontWeight:600, marginBottom:10}}>Upload History</div>
        <div style={{fontSize:13, color:'var(--text-subdued)'}}>No upload history yet.</div>
      </div>
    </div>
  </Shell>
);

// ─── SCREEN 6: DICTIONARY ──────────────────
const WaDictionary = () => {
  const persons = [
    { name: "Christian Bolger", role: "Product Manager", company: "Enersis", type: "PERSON", vars: 3 },
    { name: "Florian Wolf", role: "CTO, Managing Director", company: "Enersis", type: "PERSON", vars: 3, expanded: true },
    { name: "Michael Baz", role: "Board Member", company: "EnBW", type: "PERSON", vars: 3 },
    { name: "Monica Breitkreutz", role: "HR Manager", company: "Enersis", type: "PERSON", vars: 3 },
    { name: "Thomas Koller", role: "CEO, Head of Sales, Founder, Managing Director", company: "Enersis", type: "PERSON", vars: 3 },
  ];
  return (
    <Shell active="dictionary" title="Dictionary" topRight={
      <span className="mono" style={{fontSize:12}}>5 persons · 9 terms · 32 variations total</span>
    }>
      {/* Tabs */}
      <div style={{display:'flex', gap:0, marginBottom:20}}>
        {[["Persons",5],["Terms",9]].map(([label,count],i) => (
          <button key={label} style={{
            flex:1, padding:'10px 0', fontSize:14, fontWeight:500, textAlign:'center',
            border:'1px solid var(--border-subdued)', cursor:'pointer',
            borderRadius: i===0 ? '8px 0 0 8px' : '0 8px 8px 0',
            background: i===0 ? 'var(--text-primary)' : 'var(--container)',
            color: i===0 ? 'var(--text-inverse)' : 'var(--text-secondary)',
          }}>{label} <span style={{opacity:0.6}}>{count}</span></button>
        ))}
      </div>

      <div style={{display:'flex', justifyContent:'space-between', alignItems:'center', marginBottom:14}}>
        <input type="text" placeholder="Search persons…" style={{
          padding:'7px 12px', fontSize:13, border:'1px solid var(--border-subdued)',
          borderRadius:8, background:'var(--container)', color:'var(--text-primary)', width:180,
        }}/>
        <div style={{display:'flex', gap:8, alignItems:'center'}}>
          <FilterTabs items={[["All",6],["Active",5],["Inactive",0]]} active="All"/>
          <button className="btn btn-primary" style={{height:34, fontSize:13, padding:'0 14px'}}>+ Add Person</button>
        </div>
      </div>

      <div style={{display:'flex', flexDirection:'column', gap:0}}>
        {persons.map((p,i) => (
          <React.Fragment key={i}>
            <div style={{
              display:'flex', alignItems:'center', justifyContent:'space-between',
              padding:'12px 14px',
              borderBottom: '1px solid var(--border-subdued)',
              background: p.expanded ? 'var(--surface-inset)' : 'transparent',
            }}>
              <div style={{display:'flex', alignItems:'center', gap:10}}>
                <span className="dot dot-success" style={{width:8, height:8}}/>
                <span style={{fontWeight:500, fontSize:14}}>{p.name}</span>
                <span style={{fontSize:13, color:'var(--text-subdued)'}}>{p.role} · {p.company}</span>
              </div>
              <div style={{display:'flex', alignItems:'center', gap:8}}>
                <StatusBadge status={p.type}/>
                <span className="mono" style={{fontSize:12, color:'var(--text-subdued)'}}>{p.vars} vars</span>
              </div>
            </div>

            {/* Expanded edit form for Florian Wolf */}
            {p.expanded && (
              <div style={{padding:'16px 14px 16px 32px', borderBottom:'1px solid var(--border-subdued)', background:'var(--surface-inset)'}}>
                <div style={{display:'grid', gridTemplateColumns:'1fr 1fr', gap:12, marginBottom:12}}>
                  {[["First Name","Florian"],["Last Name","Wolf"],["Role","CTO, Managing Director"],["Company","Enersis"],["Department","Management"],["Status","Active"]].map(([label,val]) => (
                    <div key={label}>
                      <div style={{fontSize:11, fontWeight:500, textTransform:'uppercase', letterSpacing:'0.04em', color:'var(--text-subdued)', marginBottom:4}}>{label}</div>
                      <input type="text" defaultValue={val} style={{
                        width:'100%', padding:'8px 10px', fontSize:14,
                        border:'1px solid var(--border-subdued)', borderRadius:6,
                        background:'var(--container)', color:'var(--text-primary)',
                      }}/>
                    </div>
                  ))}
                </div>
                <div style={{marginBottom:12}}>
                  <div style={{fontSize:11, fontWeight:500, textTransform:'uppercase', letterSpacing:'0.04em', color:'var(--text-subdued)', marginBottom:4}}>Context / Description</div>
                  <textarea rows={2} style={{
                    width:'100%', padding:'8px 10px', fontSize:14, resize:'vertical',
                    border:'1px solid var(--border-subdued)', borderRadius:6,
                    background:'var(--container)', color:'var(--text-primary)',
                  }}/>
                </div>
                <div style={{fontSize:11, fontWeight:500, textTransform:'uppercase', letterSpacing:'0.04em', color:'var(--text-subdued)', marginBottom:6}}>
                  Variations (3) <button style={{fontSize:12, color:'var(--text-link)', background:0, border:0, cursor:'pointer', marginLeft:8}}>+ Add Variation</button>
                </div>
                <div style={{display:'flex', gap:6, flexWrap:'wrap', marginBottom:14}}>
                  {[{v:"Florian",t:"NICKNAME"},{v:"Flo",t:"NICKNAME"},{v:"Florian Wolf",t:"CANONICAL"}].map((tag,j) => (
                    <span key={j} style={{
                      display:'inline-flex', alignItems:'center', gap:4,
                      padding:'3px 10px', borderRadius:6, fontSize:12,
                      background:'var(--container)', border:'1px solid var(--border-subdued)',
                    }}>
                      {tag.v} <span style={{fontSize:10, color:'var(--text-subdued)', fontWeight:500}}>{tag.t}</span> ×
                    </span>
                  ))}
                </div>
                <div style={{display:'flex', justifyContent:'space-between', alignItems:'center'}}>
                  <button style={{fontSize:13, color:'var(--status-destructive)', background:0, border:0, cursor:'pointer', fontWeight:500}}>Delete</button>
                  <div style={{display:'flex', gap:8}}>
                    <button className="btn btn-ghost" style={{height:34, fontSize:13}}>Cancel</button>
                    <button className="btn btn-primary" style={{height:34, fontSize:13, padding:'0 14px'}}>Save Changes</button>
                  </div>
                </div>
              </div>
            )}
          </React.Fragment>
        ))}
      </div>
    </Shell>
  );
};

// ─── SCREEN 7: SETTINGS ──────────────────
const WaSettings = () => (
  <Shell active="settings" title="Settings" topRight={
    <span className="mono" style={{fontSize:12}}>5 persons · 9 terms · 32 variations · 35 transcripts</span>
  }>
    <div style={{maxWidth:680, display:'flex', flexDirection:'column', gap:24}}>
      {/* CSV Import */}
      <div className="card" style={{padding:20}}>
        <div style={{display:'flex', justifyContent:'space-between', alignItems:'center', marginBottom:10}}>
          <div style={{display:'flex', alignItems:'center', gap:10}}>
            <span style={{fontSize:18}}>↑</span>
            <span style={{fontSize:15, fontWeight:600}}>Import from NocoDB CSV</span>
          </div>
          <StatusBadge status="SUBMITTED"/>
        </div>
        <p style={{fontSize:13, color:'var(--text-secondary)', lineHeight:1.5, marginBottom:14}}>
          Upload NocoDB CSV exports to import persons, terms, and their variations. The import uses upsert logic.
        </p>
        <div style={{
          border:'2px dashed var(--border-subdued)', borderRadius:8,
          padding:'20px', textAlign:'center', fontSize:13, color:'var(--text-subdued)',
        }}>
          Drop CSV files here or <span style={{color:'var(--text-link)', cursor:'pointer'}}>browse</span>
        </div>
      </div>

      {/* LightRAG Sync */}
      <div className="card" style={{padding:20}}>
        <div style={{display:'flex', justifyContent:'space-between', alignItems:'center', marginBottom:10}}>
          <span style={{fontSize:15, fontWeight:600}}>Skeleton Sync (LightRAG)</span>
          <span style={{fontSize:11, fontWeight:600, letterSpacing:'0.04em', color:'var(--text-link)'}}>BONES</span>
        </div>
        <p style={{fontSize:13, color:'var(--text-secondary)', lineHeight:1.5, marginBottom:14}}>
          Sync structural knowledge (persons, terms, org units, initiatives) to LightRAG as individual bone documents.
        </p>
        <div style={{display:'grid', gridTemplateColumns:'repeat(4,1fr)', gap:12, marginBottom:14}}>
          {[
            {n:809, label:"Synced", color:"var(--status-success)"},
            {n:0, label:"Pending", color:"var(--status-warning)"},
            {n:0, label:"Failed", color:"var(--status-destructive)"},
            {n:809, label:"Total", color:"var(--text-primary)"},
          ].map((s,i) => (
            <div key={i} style={{textAlign:'center', padding:'12px 0', borderRadius:8, border:'1px solid var(--border-subdued)'}}>
              <div style={{fontSize:22, fontWeight:600, color:s.color, fontVariantNumeric:'tabular-nums'}}>{s.n}</div>
              <div style={{fontSize:11, color:'var(--text-subdued)', marginTop:2}}>{s.label}</div>
            </div>
          ))}
        </div>
        <div style={{display:'flex', gap:8, justifyContent:'center'}}>
          <button className="btn btn-secondary" style={{height:34, fontSize:13}}>Preview Changes</button>
          <button className="btn btn-primary" style={{height:34, fontSize:13, padding:'0 14px'}}>Sync Now</button>
          <button className="btn btn-destructive" style={{height:34, fontSize:13, padding:'0 14px'}}>Full Sync (Force)</button>
        </div>
      </div>

      {/* Config */}
      <div className="card" style={{padding:20}}>
        <div style={{display:'flex', justifyContent:'space-between', alignItems:'center', marginBottom:14}}>
          <span style={{fontSize:15, fontWeight:600}}>Settings</span>
          <span style={{fontSize:11, fontWeight:600, letterSpacing:'0.04em', color:'var(--text-subdued)'}}>CONFIG</span>
        </div>
        <p style={{fontSize:13, color:'var(--text-secondary)', marginBottom:14}}>Configure external service URLs and integrations. Changes are saved immediately.</p>
        {[["LightRAG Service URL","http://192.168.2.18:9621"],["LightRAG API Key",""]].map(([label,val]) => (
          <div key={label} style={{marginBottom:12}}>
            <div style={{fontSize:12, fontWeight:500, marginBottom:4}}>{label}</div>
            <input type="text" defaultValue={val} placeholder={val || "Leave empty if no auth required"} style={{
              width:'100%', padding:'8px 10px', fontSize:14,
              border:'1px solid var(--border-subdued)', borderRadius:6,
              background:'var(--container)', color:'var(--text-primary)',
              fontFamily:'var(--mono)', fontSize:13,
            }}/>
          </div>
        ))}
        <button className="btn btn-primary" style={{height:34, fontSize:13, padding:'0 14px', marginTop:4}}>Save</button>
      </div>

      {/* Danger Zone */}
      <div style={{
        border:'1px solid rgba(236,34,34,0.20)', borderRadius:10, padding:20,
        background:'rgba(236,34,34,0.03)',
      }}>
        <div style={{fontSize:15, fontWeight:600, color:'var(--status-destructive)', marginBottom:14}}>Danger Zone</div>
        <div style={{display:'grid', gridTemplateColumns:'1fr 1fr', gap:16}}>
          {[["Clear Dictionary","Delete all persons, terms, and variations. Transcripts are kept."],["Reset Everything","Delete all data: dictionary, transcripts, and review log."]].map(([title,desc]) => (
            <div key={title}>
              <div style={{fontSize:14, fontWeight:500, marginBottom:4}}>{title}</div>
              <div style={{fontSize:12, color:'var(--text-secondary)', marginBottom:10, lineHeight:1.4}}>{desc}</div>
              <button className="btn btn-destructive btn-full" style={{height:36, fontSize:13}}>{title}</button>
            </div>
          ))}
        </div>
      </div>
    </div>
  </Shell>
);

Object.assign(window, { WaOverview, WaTranscript, WaProcess, WaHarvest, WaIngest, WaDictionary, WaSettings });
