// Screen 7 — Onboarding (3 screens)
// Screen 8 — Server review HTMX

const OnboardStep = ({ step = 1, state }) => {
  const titles = {1: "Server prüfen", 2: "Bearer-Token", 3: "Stimmen-Probe"};
  return (
    <div className="iphone vd-frame">
      <StatusBar />
      <div className="screen">
        <FlowHeader title={titles[step]} total={3} current={step} />

        <div style={{padding:'0 24px 0', flex:1, display:'flex', flexDirection:'column'}}>
          {step === 1 && (
            <>
              <div className="c-secondary" style={{fontSize:16, lineHeight:1.5, marginBottom:28}}>
                Voice Diary läuft auf deinem Heimserver. Stell sicher, dass dein iPhone im Tailnet ist.
              </div>

              <div className="card" style={{padding:0, overflow:'hidden'}}>
                <div style={{padding:'14px 16px', borderBottom:'1px solid var(--border-subdued)'}}>
                  <div className="t-mono-cap c-subdued" style={{marginBottom:4}}>SERVER</div>
                  <div className="mono" style={{fontSize:14}}>voice-diary.tail-1a2b.ts.net</div>
                </div>
                <div style={{padding:'14px 16px', display:'flex', alignItems:'center', gap:10}}>
                  {state === "ok" && <><span className="dot dot-success"/><span style={{fontSize:15}}>Erreichbar · 38 ms</span></>}
                  {state === "down" && <><span className="dot dot-rec"/><span style={{fontSize:15, color:'var(--status-destructive)'}}>Nicht erreichbar</span></>}
                  {state === "degraded" && <><span className="dot dot-warn"/><span style={{fontSize:15, color:'var(--status-warning)'}}>Eingeschränkt — Calendar API down</span></>}
                  {!state && <><span className="dot dot-subdued"/><span style={{fontSize:15, color:'var(--text-subdued)'}}>Noch nicht geprüft</span></>}
                </div>
              </div>

              <div style={{flex:1}}/>

              <button className="btn btn-primary btn-full btn-lg" style={state==="down"?{}:{}}>
                {state ? "Erneut prüfen" : "Server prüfen"}
              </button>
              <div style={{height:12}}/>
              <button className="btn btn-primary btn-full btn-lg" disabled={state !== "ok"} style={state!=="ok"?{opacity:0.35}:{}}>
                Weiter
              </button>
              <div style={{height:24}}/>
            </>
          )}

          {step === 2 && (
            <>
              <div className="c-secondary" style={{fontSize:16, lineHeight:1.5, marginBottom:28}}>
                Der Token, den du bei der Server-Installation generiert hast. Wird im Schlüsselbund gespeichert.
              </div>

              <div className="t-mono-cap c-subdued" style={{marginBottom:6}}>SERVER</div>
              <div className="mono" style={{fontSize:14, color:'var(--text-secondary)', marginBottom:20}}>voice-diary.tail-1a2b.ts.net</div>

              <div className="t-mono-cap c-subdued" style={{marginBottom:6}}>TOKEN</div>
              <div className="field field-mono" style={{letterSpacing:'0.1em', color:'var(--text-secondary)'}}>
                ••••••••••••••••••••••••
              </div>
              <div className="t-mono-cap c-subdued" style={{marginTop:6}}>32 ZEICHEN · GESPEICHERT</div>

              <div style={{flex:1}}/>

              <button className="btn btn-primary btn-full btn-lg">Speichern</button>
              <div style={{height:12}}/>
              <button className="btn btn-ghost btn-full" style={{color:'var(--text-link)'}}>Im Wiki nachschlagen</button>
              <div style={{height:24}}/>
            </>
          )}

          {step === 3 && (
            <>
              <div className="c-secondary" style={{fontSize:16, lineHeight:1.5, marginBottom:28}}>
                So klingt der Editor in deiner Sitzung.
              </div>

              <div className="card" style={{padding:'18px 16px', marginBottom:12}}>
                <div className="t-mono-cap c-subdued" style={{marginBottom:8}}>DEUTSCH · ANNA</div>
                <div style={{fontSize:16, lineHeight:1.4, color:'var(--text-secondary)', marginBottom:14}}>
                  „Heute hattest du drei Termine. Los geht's mit dem ersten."
                </div>
                <button style={{display:'inline-flex',alignItems:'center',gap:8, background:'rgba(21,112,239,0.10)', color:'var(--text-link)', border:0, padding:'8px 14px', borderRadius:'var(--r-pill)', fontSize:14, fontWeight:500, cursor:'pointer'}}>
                  {I.play({size:11})} Anhören
                </button>
              </div>

              <div className="card" style={{padding:'18px 16px'}}>
                <div className="t-mono-cap c-subdued" style={{marginBottom:8}}>ENGLISH · AVA</div>
                <div style={{fontSize:16, lineHeight:1.4, color:'var(--text-secondary)', marginBottom:14}}>
                  „You had three meetings today. Let's start with the first."
                </div>
                <button style={{display:'inline-flex',alignItems:'center',gap:8, background:'rgba(21,112,239,0.10)', color:'var(--text-link)', border:0, padding:'8px 14px', borderRadius:'var(--r-pill)', fontSize:14, fontWeight:500, cursor:'pointer'}}>
                  {I.play({size:11})} Listen
                </button>
              </div>

              <div style={{flex:1}}/>

              <button className="btn btn-primary btn-full btn-lg">Fertig</button>
              <div style={{height:12}}/>
              <button className="btn btn-ghost btn-full" style={{color:'var(--text-link)'}}>Stimmen anpassen</button>
              <div style={{height:24}}/>
            </>
          )}
        </div>
      </div>
      <HomeIndicator/>
    </div>
  );
};

const ServerReview = ({ variant = "in-progress" }) => {
  // Server screen — desktop-ish layout. We render at 720px wide.
  const Entity = ({ children, kind = "pending" }) => (
    <span className={"entity " + kind}>{children}</span>
  );
  return (
    <div className="vd-frame" style={{width:920, height:720, background:'var(--surface)', position:'relative', overflow:'hidden'}}>
      {/* Browser-ish top bar */}
      <div style={{
        height:44, borderBottom:'1px solid var(--border-subdued)',
        display:'flex', alignItems:'center', padding:'0 20px',
        background:'var(--container)', gap:14,
      }}>
        <div style={{display:'flex',gap:6}}>
          <span style={{width:11,height:11,borderRadius:'50%',background:'#FF5F57'}}/>
          <span style={{width:11,height:11,borderRadius:'50%',background:'#FEBC2E'}}/>
          <span style={{width:11,height:11,borderRadius:'50%',background:'#28C840'}}/>
        </div>
        <div style={{flex:1, display:'flex', justifyContent:'center'}}>
          <div className="mono" style={{fontSize:12, color:'var(--text-subdued)', background:'var(--container-inset)', padding:'4px 12px', borderRadius:'var(--r-md)'}}>
            voice-diary.tail-1a2b.ts.net/review/sessions/ses_2026-04-30_a7f3c1
          </div>
        </div>
        <div style={{fontSize:13, color:'var(--text-subdued)'}}>Voice Diary · Review</div>
      </div>

      {/* Page */}
      <div style={{padding:'40px 0 100px', maxWidth:720, margin:'0 auto', height:'calc(100% - 44px)', overflowY:'auto'}}>
        <div style={{padding:'0 24px'}}>
          <div className="t-mono-cap c-subdued" style={{marginBottom:8}}>SES_2026-04-30_A7F3C1 · 21:42</div>
          <div className="t-title" style={{fontSize:24, marginBottom:6}}>Entitäten prüfen</div>
          <div className="c-secondary" style={{fontSize:15, marginBottom:28, lineHeight:1.5}}>
            8 Entitäten erkannt. Klicke an, um zu bestätigen oder zu korrigieren.
          </div>

          <div style={{display:'flex', gap:18, fontSize:12, color:'var(--text-subdued)', marginBottom:24, letterSpacing:'0.04em', textTransform:'uppercase', fontWeight:500}}>
            <span><span className="dot dot-success" style={{width:7,height:7,display:'inline-block',marginRight:6,verticalAlign:'middle'}}/>3 bestätigt</span>
            <span><span className="dot dot-link" style={{width:7,height:7,display:'inline-block',marginRight:6,verticalAlign:'middle'}}/>{variant==='complete'?0:4} offen</span>
            <span><span className="dot dot-subdued" style={{width:7,height:7,display:'inline-block',marginRight:6,verticalAlign:'middle'}}/>1 verworfen</span>
          </div>

          <div style={{fontSize:16, lineHeight:1.85, color:'var(--text-primary)'}}>
            <p className="transcript-line">
              Heute hatte ich ein 1:1 mit <Entity kind={variant==='complete'?'confirmed':'confirmed'}>Maya</Entity>.
              Sie ist im Q3 ziemlich überlastet und hat angefragt, dass wir die Architecture-Review-Sessions
              komprimieren. Habe ihr zugesagt, mit <Entity kind={variant==='complete'?'confirmed':'confirmed'}>Stephan</Entity> zu sprechen.
            </p>
            <p className="transcript-line">
              Danach kam der Customer-Call mit <Entity kind={variant==='complete'?'confirmed':'pending'}>Kestrel</Entity> —
              spezifisch mit ihrem CTO, <Entity kind={variant==='complete'?'confirmed':'pending'}>James Vendrell</Entity>.
              Sie wollen ihren Vertrag verlängern, aber ihr Pricing-Modell hat sich verändert.
              Wir müssen das mit <Entity kind={variant==='complete'?'confirmed':'pending'}>Lara</Entity> diskutieren.
            </p>
            <p className="transcript-line">
              Quartals-Review mit <Entity kind={variant==='complete'?'confirmed':'pending'}>Stephan</Entity> war
              überraschend ruhig. Er hat <Entity kind="rejected">Maya</Entity> nicht erwähnt — was eigentlich gut ist.
            </p>
            <p className="transcript-line">
              Abends Eltern-Abend in <Entity kind={variant==='complete'?'confirmed':'confirmed'}>Linas</Entity> Schule.
            </p>
          </div>

          {/* Pending entity confirmation card */}
          {variant !== 'complete' && (
            <div className="card" style={{marginTop:32, padding:'18px 20px', maxWidth:520}}>
              <div className="t-mono-cap c-subdued" style={{marginBottom:8}}>BESTÄTIGEN · 1 / 4 OFFEN</div>
              <div style={{fontSize:18, marginBottom:4}}>James Vendrell</div>
              <div className="c-secondary" style={{fontSize:14, marginBottom:16}}>
                Erkannt als <span className="mono" style={{fontSize:13}}>person</span> · neue Person, kein Match im Wörterbuch.
              </div>
              <div style={{display:'flex', gap:8}}>
                <button className="btn btn-primary" style={{height:40, padding:'0 18px', fontSize:15}}>Bestätigen</button>
                <button className="btn btn-secondary" style={{height:40}}>Korrigieren</button>
                <button className="btn btn-ghost" style={{height:40}}>Überspringen</button>
              </div>
            </div>
          )}
        </div>
      </div>

      {/* Sticky action bar */}
      <div style={{
        position:'absolute', left:0, right:0, bottom:0,
        background:'var(--container)',
        borderTop:'1px solid var(--border-subdued)',
        padding:'14px 24px',
        display:'flex', alignItems:'center', justifyContent:'space-between',
      }}>
        <div className="c-secondary" style={{fontSize:13}}>
          {variant === 'complete' ? '8 Entitäten geprüft · 7 bestätigt, 1 verworfen' : '3 von 8 bestätigt · ↩ überspringt'}
        </div>
        <div style={{display:'flex', gap:8}}>
          <button className="btn btn-ghost" style={{height:40}}>Verwerfen</button>
          <button className="btn btn-primary" style={{height:40, padding:'0 22px', fontSize:15}} disabled={variant!=='complete'} >
            {variant === 'complete' ? 'Fertig & schließen' : 'Fertig'}
          </button>
        </div>
      </div>
    </div>
  );
};

Object.assign(window, { OnboardStep, ServerReview });
