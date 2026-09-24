// Shared icon set + small primitives for Voice Diary screens
// Icons are simple stroke SVGs (lucide-style) — kept minimal per design ethos.

const Icon = ({ d, size = 18, stroke = 1.6, fill = "none", style = {} }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" fill={fill} stroke="currentColor" strokeWidth={stroke} strokeLinecap="round" strokeLinejoin="round" style={style}>
    {typeof d === "string" ? <path d={d} /> : d}
  </svg>
);

const I = {
  mic: <Icon d="M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3Zm-7 10a7 7 0 0 0 14 0M12 19v3" />,
  micFill: (props) => (
    <svg width={props?.size||18} height={props?.size||18} viewBox="0 0 24 24" fill="currentColor">
      <rect x="9" y="2" width="6" height="13" rx="3"/>
      <path d="M5 11a7 7 0 0 0 14 0" stroke="currentColor" strokeWidth="1.6" fill="none" strokeLinecap="round"/>
      <path d="M12 18v3" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round"/>
    </svg>
  ),
  chevronR: <Icon d="m9 6 6 6-6 6" />,
  chevronL: <Icon d="m15 6-6 6 6 6" />,
  chevronD: <Icon d="m6 9 6 6 6-6" />,
  calendar: <Icon d="M3 6.5A2.5 2.5 0 0 1 5.5 4h13A2.5 2.5 0 0 1 21 6.5v12A2.5 2.5 0 0 1 18.5 21h-13A2.5 2.5 0 0 1 3 18.5v-12ZM3 9h18M8 2v4M16 2v4" />,
  sun: <Icon d={<g><circle cx="12" cy="12" r="4" /><path d="M12 2v2M12 20v2M4 12H2M22 12h-2M5 5l1.5 1.5M17.5 17.5 19 19M5 19l1.5-1.5M17.5 6.5 19 5"/></g>} />,
  sunHorizon: <Icon d={<g><circle cx="12" cy="14" r="3.5" /><path d="M2 19h20M5 14l1.4-1.4M17.6 12.6 19 14M12 8v2"/></g>} />,
  check: <Icon d="m5 12 5 5L20 7" stroke={2.2} />,
  checkCircle: (props) => (
    <svg width={props?.size||18} height={props?.size||18} viewBox="0 0 24 24" fill="currentColor">
      <circle cx="12" cy="12" r="10"/>
      <path d="m7.5 12.2 3.2 3.2L16.7 9.4" stroke="#fff" strokeWidth="2" fill="none" strokeLinecap="round" strokeLinejoin="round"/>
    </svg>
  ),
  x: <Icon d="M6 6l12 12M18 6 6 18" />,
  play: (props) => (
    <svg width={props?.size||14} height={props?.size||14} viewBox="0 0 24 24" fill="currentColor">
      <path d="M7 5v14l12-7z"/>
    </svg>
  ),
  users: <Icon d={<g><circle cx="9" cy="8" r="3.5"/><path d="M2 20c0-3.5 3-6 7-6s7 2.5 7 6"/><circle cx="17" cy="9" r="2.5"/><path d="M16 14.5c3 .3 5 2.3 5 5"/></g>} />,
  edit: <Icon d="M4 20h4l11-11-4-4L4 16v4ZM14 5l4 4" />,
  question: <Icon d={<g><circle cx="12" cy="12" r="9"/><path d="M9.5 9.5a2.5 2.5 0 1 1 3.5 2.3c-.7.3-1 .8-1 1.5V14M12 17.5h.01"/></g>} />,
  settings: <Icon d={<g><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06A1.65 1.65 0 0 0 15 19.4a1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.6 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.6a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1Z"/></g>} />,
  notebook: <Icon d="M4 4.5A2.5 2.5 0 0 1 6.5 2h11A2.5 2.5 0 0 1 20 4.5v15a2.5 2.5 0 0 1-2.5 2.5h-11A2.5 2.5 0 0 1 4 19.5v-15ZM4 8h2M4 12h2M4 16h2" />,
  list: <Icon d="M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01" />,
  battery: <Icon d={<g><rect x="2" y="8" width="18" height="8" rx="2"/><path d="M22 11v2"/></g>} />,
  wifi: <Icon d={<g><path d="M2 9c5-5 15-5 20 0M5 12.5c3.5-3.5 10.5-3.5 14 0M8.5 16c1.5-1.5 5.5-1.5 7 0"/><circle cx="12" cy="19" r="1" fill="currentColor"/></g>} />,
  lock: <Icon d={<g><rect x="4" y="11" width="16" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/></g>} />,
  shield: <Icon d="M12 3 4 6v6c0 4.5 3.3 8.5 8 9 4.7-.5 8-4.5 8-9V6l-8-3Z" />,
  speaker: <Icon d="M3 9v6h4l5 4V5L7 9H3ZM16 9a3 3 0 0 1 0 6M19 6a7 7 0 0 1 0 12" />,
  pause: (props) => (
    <svg width={props?.size||18} height={props?.size||18} viewBox="0 0 24 24" fill="currentColor">
      <rect x="6" y="5" width="4" height="14" rx="1"/><rect x="14" y="5" width="4" height="14" rx="1"/>
    </svg>
  ),
  stop: (props) => (
    <svg width={props?.size||18} height={props?.size||18} viewBox="0 0 24 24" fill="currentColor">
      <rect x="6" y="6" width="12" height="12" rx="2"/>
    </svg>
  ),
};

const StatusBar = ({ time = "21:42", islandState = null }) => {
  // islandState: null | "recording" | "speaking" | "listening"
  const labels = {
    recording: { text: "Aufnahme läuft", color: "#EC2222", dot: "rec" },
    speaking:  { text: "Editor spricht", color: "#FF9F0A", dot: "warn" },
    listening: { text: "höre zu",        color: "#EC2222", dot: "rec" },
  };
  const l = labels[islandState];
  return (
    <div className="vd-statusbar">
      <span>{time}</span>
      <span className={"vd-island " + (islandState ? "expanded " + islandState : "")} aria-hidden="true">
        {l && (
          <span className="vd-island-content">
            <span className={"dot dot-" + l.dot + (islandState !== "speaking" ? " pulse" : "")}/>
            <span className="vd-island-label">{l.text}</span>
          </span>
        )}
      </span>
      <span className="right">
        <span style={{display:'inline-flex',gap:4,alignItems:'center'}}>
          <svg width="17" height="11" viewBox="0 0 17 11" fill="currentColor"><path d="M1 7.5h2v3H1zM5 5.5h2v5H5zM9 3h2v7.5H9zM13 .5h2v10h-2z"/></svg>
          <svg width="16" height="11" viewBox="0 0 16 11" fill="none" stroke="currentColor" strokeWidth="1.2"><path d="M.5 4C2.5 2 5 1 8 1s5.5 1 7.5 3M3 6.5C4.5 5 6.2 4.2 8 4.2s3.5.8 5 2.3M5.5 9c.7-.7 1.6-1 2.5-1s1.8.3 2.5 1"/><circle cx="8" cy="10.2" r=".7" fill="currentColor"/></svg>
          <svg width="24" height="11" viewBox="0 0 24 11" fill="none">
            <rect x="0.5" y="0.5" width="20" height="10" rx="2.5" stroke="currentColor" opacity="0.4"/>
            <rect x="2" y="2" width="14" height="7" rx="1.2" fill="currentColor"/>
            <rect x="21" y="3.5" width="1.5" height="4" rx="0.5" fill="currentColor" opacity="0.4"/>
          </svg>
        </span>
      </span>
    </div>
  );
};

const TabBar = ({ active = "abend" }) => {
  const tabs = [
    { id: "abend", label: "Abend", icon: I.notebook },
    { id: "aufnahme", label: "Aufnahme", icon: I.micFill },
    { id: "verlauf", label: "Verlauf", icon: I.list },
    { id: "stimmen", label: "Stimmen", icon: I.settings },
  ];
  return (
    <div className="vd-tabbar">
      {tabs.map(t => (
        <div key={t.id} className={"tab " + (active === t.id ? "active" : "")}>
          {typeof t.icon === 'function' ? t.icon({size:22}) : <span style={{display:'inline-block'}}>{React.cloneElement(t.icon, {size: 22, stroke: 1.5})}</span>}
          <span>{t.label}</span>
        </div>
      ))}
    </div>
  );
};

const HomeIndicator = () => (
  <div style={{position:'absolute', bottom:8, left:'50%', transform:'translateX(-50%)', width:134, height:5, borderRadius:3, background:'var(--text-primary)', opacity:0.9}}/>
);

// Global state indicator — top-center, sits below the dynamic island.
// One anchor for "is the mic open / who is talking?".
const StateIndicator = ({ state }) => {
  if (!state) return null;
  if (state === "recording") return (
    <div className="state-indicator recording">
      <span className="dot dot-rec pulse"/>
      <span>Aufnahme läuft</span>
    </div>
  );
  if (state === "speaking") return (
    <div className="state-indicator speaking">
      <span className="dot dot-warn"/>
      <span>Editor spricht</span>
    </div>
  );
  if (state === "listening") return (
    <div className="state-indicator listening">
      <span className="dot dot-rec pulse"/>
      <span>höre zu</span>
    </div>
  );
  return null;
};

// FlowHeader — unified in-flow modal header. Reserves a fixed-height progress
// row so screens with and without a progress bar align at the same Y.
const FlowHeader = ({ title, total, current, onClose, hasProgress = true }) => (
  <>
    <div style={{height:32, padding:'12px 16px 0', display:'flex', alignItems:'center', gap:12}}>
      <div style={{flex:1, display:'flex', gap:6}}>
        {hasProgress && Array.from({length: total}).map((_, i) => (
          <div key={i} style={{
            flex:1, height:3, borderRadius:2,
            background: i < current ? 'var(--text-primary)' : 'var(--border-subdued)',
          }}/>
        ))}
      </div>
      {hasProgress && (
        <button style={{background:'transparent', border:0, color:'var(--text-subdued)', cursor:'pointer', padding:4, display:'flex', alignItems:'center'}} aria-label="Schließen">
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"><path d="M6 6l12 12M18 6 6 18"/></svg>
        </button>
      )}
    </div>
    <div className="nav-large" style={{padding:'20px 16px 16px'}}>
      <div className="title">{title}</div>
    </div>
  </>
);

Object.assign(window, { I, Icon, StatusBar, TabBar, HomeIndicator, StateIndicator, FlowHeader });
