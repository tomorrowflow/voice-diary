// Screen 3 — Todo confirmation card
// Screen 4 — Voice picker
// Screen 6 — Capture (Aufnahme)

const TodoConfirm = ({ state = "idle" }) => {
  // state: "idle" | "listening" | "refining"
  const candidate = "Stephan morgen wegen Q3-Targets anrufen";
  return (
    <div className="iphone vd-frame">
      <StatusBar />
      <div className="screen">
        <FlowHeader title="Eine Sache noch" total={4} current={3} />

        <div style={{padding:'0 16px 0', display:'flex', flexDirection:'column', gap:16, flex:1}}>
          <div className="card-inset" style={{padding:'14px 16px'}}>
            <div className="t-mono-cap c-subdued" style={{marginBottom:6}}>EDITOR</div>
            <div style={{fontSize:16, lineHeight:1.5, color:'var(--text-secondary)'}}>
              „Ja, nein, oder anders?"
            </div>
          </div>

          {/* Candidate notebook line */}
          <div style={{padding:'16px 4px 16px'}}>
            <div className="t-mono-cap c-subdued" style={{marginBottom:14}}>AUFGABE</div>
            <div style={{
              fontSize: 24,
              lineHeight: 1.35,
              fontWeight: 500,
              letterSpacing: '-0.005em',
              borderBottom: '1px solid var(--border-subdued)',
              paddingBottom: 14,
            }}>
              {candidate}
            </div>
            {state === "listening" && (
              <div style={{display:'flex',alignItems:'center',gap:8, marginTop:12}}>
                <span className="dot" style={{background:'var(--status-destructive)', width:8, height:8}}/>
                <span style={{fontSize:13, color:'var(--text-subdued)'}}>höre dich</span>
              </div>
            )}
          </div>

          {state === "refining" && (
            <div style={{display:'flex',flexDirection:'column',gap:10}}>
              <textarea
                className="field"
                rows={2}
                defaultValue={candidate}
                style={{fontFamily:'var(--font)', fontSize:16, lineHeight:1.4, resize:'none'}}
              />
              <div style={{display:'flex',gap:8}}>
                <button className="btn btn-ghost" style={{flex:1}}>Abbrechen</button>
                <button className="btn btn-primary" style={{flex:1, height:44}}>Übernehmen</button>
              </div>
            </div>
          )}

          <div style={{flex:1}}/>

          {state !== "refining" && (
            <div style={{display:'flex', flexDirection:'column', gap:10, paddingBottom:8}}>
              <div style={{display:'flex', gap:8}}>
                <button className="btn btn-secondary" style={{flex:1, height:44}}>{React.cloneElement(I.edit,{size:14})}<span style={{marginLeft:6}}>Anders</span></button>
                <button className="btn btn-secondary" style={{flex:1, height:44, color:'var(--status-destructive)', borderColor:'var(--status-destructive)'}}>Nein</button>
              </div>
              <button className="btn btn-primary btn-full btn-lg">Ja, übernehmen</button>
            </div>
          )}
        </div>

        <TabBar active="abend"/>
      </div>
      <HomeIndicator/>
    </div>
  );
};

const VoiceRow = ({ name, locale, quality, selected, isAuto }) => (
  <div style={{
    display:'flex', alignItems:'center', gap:12,
    padding:'14px 16px',
    borderBottom:'1px solid var(--border-subdued)',
    background: selected ? 'rgba(21,112,239,0.04)' : 'transparent',
  }}>
    <div className={"radio " + (selected ? "checked" : "")}>
      {selected && React.cloneElement(I.check, {size:12, stroke:2.4})}
    </div>
    <div style={{flex:1, minWidth:0}}>
      <div style={{display:'flex', alignItems:'center', gap:8, marginBottom:2}}>
        <span style={{fontSize:16, fontWeight: isAuto ? 500 : 400}}>{name}</span>
        {!isAuto && quality && (
          <span className={"qbadge qbadge-" + quality}>
            {quality === 'premium' ? 'Premium' : quality === 'enhanced' ? 'Enhanced' : 'Standard'}
          </span>
        )}
      </div>
      <div className="mono" style={{fontSize:12, color:'var(--text-subdued)'}}>
        {isAuto ? "Beste verfügbare Premium-Stimme" : locale}
      </div>
    </div>
    {!isAuto && (
      <button style={{
        width:32, height:32, borderRadius:'50%',
        border:0, background:'rgba(21,112,239,0.10)',
        color:'var(--text-link)',
        display:'flex', alignItems:'center', justifyContent:'center',
        cursor:'pointer', paddingLeft:2,
      }}>
        {I.play({size:12})}
      </button>
    )}
  </div>
);

const VoicePicker = ({ variant = "rich" }) => {
  const richDE = [
    { name:"Anna", locale:"de-DE", quality:"premium", selected:false },
    { name:"Markus", locale:"de-DE", quality:"enhanced", selected:false },
    { name:"Petra", locale:"de-AT", quality:"enhanced", selected:false },
    { name:"Helena", locale:"de-DE", quality:"standard", selected:false },
  ];
  const richEN = [
    { name:"Ava", locale:"en-US", quality:"premium", selected:true },
    { name:"Daniel", locale:"en-GB", quality:"enhanced", selected:false },
    { name:"Samantha", locale:"en-US", quality:"standard", selected:false },
  ];

  return (
    <div className="iphone vd-frame">
      <StatusBar />
      <div className="screen">
        <FlowHeader title="Stimmen" hasProgress={false} />
        <div className="screen-body scroll" style={{padding:'0 0 100px'}}>
          <div style={{padding:'0 16px 20px'}}>
            <div className="t-body c-secondary" style={{fontSize:15}}>
              Eine Stimme pro Sprache. Apple-Stimmen, lokal auf dem Gerät.
            </div>
          </div>

          {/* Deutsch */}
          <div className="sec-h" style={{padding:'0 16px', marginBottom:8}}>Deutsch</div>
          <div style={{
            background:'var(--container)',
            border:'1px solid var(--border-subdued)',
            borderRadius:'var(--r-lg)',
            margin:'0 16px',
            overflow:'hidden',
          }}>
            <VoiceRow name="Automatisch" isAuto selected={variant==="rich"}/>
            {variant === "rich" && richDE.map((v,i) => <VoiceRow key={i} {...v} />)}
            {variant === "sparse" && (
              <div style={{padding:'18px 16px'}}>
                <div style={{fontSize:14, color:'var(--text-subdued)', lineHeight:1.5}}>
                  Keine deutschen Stimmen installiert.
                  <span style={{color:'var(--text-link)', display:'block', marginTop:6}}>
                    iOS-Einstellungen → Bedienungshilfen → Gesprochene Inhalte → Stimmen ↗
                  </span>
                </div>
              </div>
            )}
          </div>

          <div style={{height:24}}/>

          {/* English */}
          <div className="sec-h" style={{padding:'0 16px', marginBottom:8}}>English</div>
          <div style={{
            background:'var(--container)',
            border:'1px solid var(--border-subdued)',
            borderRadius:'var(--r-lg)',
            margin:'0 16px',
            overflow:'hidden',
          }}>
            <VoiceRow name="Automatic" isAuto selected={false}/>
            {richEN.map((v,i) => <VoiceRow key={i} {...v} />)}
          </div>

          <div style={{padding:'20px 16px', fontSize:13, color:'var(--text-subdued)', lineHeight:1.5}}>
            Premium-Stimmen erfordern einen einmaligen Download (~100 MB) über die iOS-Einstellungen.
          </div>
        </div>

        <TabBar active="stimmen"/>
      </div>
      <HomeIndicator/>
    </div>
  );
};

const Capture = ({ recording = false }) => (
  <div className="iphone vd-frame">
    <StatusBar islandState={recording ? "recording" : null} />
    <div className="screen">
      <FlowHeader title="Aufnahme" hasProgress={false} />

      {/* Top half: state-dependent display (timer or resting mic) */}
      <div style={{flex:1, display:'flex', flexDirection:'column', alignItems:'center', justifyContent:'center', padding:'0 32px', minHeight:0}}>
        {recording ? (
          <>
            <div className="mono tnum" style={{fontSize:64, fontWeight:400, letterSpacing:'-0.02em', marginBottom:8, color:'var(--text-primary)'}}>
              00:42
            </div>
            <div className="c-subdued" style={{fontSize:13, letterSpacing:'0.04em', textTransform:'uppercase', fontWeight:500}}>seit Aufnahmestart</div>
          </>
        ) : (
          <>
            <div style={{
              width:120, height:120, borderRadius:'50%',
              background:'var(--container-inset)',
              display:'flex', alignItems:'center', justifyContent:'center',
              marginBottom:32,
              color:'var(--text-primary)',
            }}>
              {I.micFill({size:48})}
            </div>
            <div className="t-title" style={{fontSize:24, marginBottom:8, textAlign:'center'}}>
              Schnell festhalten
            </div>
            <div className="c-secondary" style={{fontSize:16, textAlign:'center', lineHeight:1.5, maxWidth:280}}>
              30 – 90 Sekunden. Wird im Hintergrund hochgeladen, wenn du fertig bist.
            </div>
          </>
        )}
      </div>

      {/* Sticky bottom: round button at SAME HEIGHT in both states (consistent tap target). */}
      <div className="bottom-stack">
        {recording ? (
          <button className="btn btn-destructive btn-full" style={{height:60, borderRadius:'var(--r-pill)', fontSize:17, fontWeight:500}}>
            {I.stop({size:18})}
            <span style={{marginLeft:8}}>Stopp</span>
          </button>
        ) : (
          <button className="btn btn-primary btn-full" style={{height:60, borderRadius:'var(--r-pill)', fontSize:17, fontWeight:500}}>
            {I.micFill({size:18})}
            <span style={{marginLeft:8}}>Aufnahme starten</span>
          </button>
        )}
        <div style={{textAlign:'center', fontSize:13, color:'var(--text-subdued)', lineHeight:1.5, paddingTop:4}}>
          {recording
            ? <>Sage <span className="mono" style={{color:'var(--text-secondary)'}}>„hey voice diary"</span> um eine Frage zu stellen.</>
            : <>Oder drücke den <span style={{color:'var(--text-secondary)'}}>Action-Knopf</span>.</>
          }
        </div>
      </div>

      <TabBar active="aufnahme"/>
    </div>
    <HomeIndicator/>
  </div>
);

Object.assign(window, { TodoConfirm, VoicePicker, Capture });
