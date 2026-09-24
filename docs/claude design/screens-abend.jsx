// Screen 1 — Walkthrough (in-session Abend)
// Screen 2 — Day overview (Abend start)
// Screen 5 — Done card

const Walkthrough = ({ state = "recording" }) => {
  // state: "recording" | "speaking" | "listening"
  const stateLabel = {
    recording: "seit Aufnahmestart",
    speaking: "seit Aufnahmestart",
    listening: "seit Aufnahmestart",
  }[state];

  return (
    <div className="iphone vd-frame">
      <StatusBar islandState={state} />
      <div className="screen">
        <FlowHeader title="Quartals-Review mit Stephan" total={5} current={2} />

        <div style={{padding:'0 16px 0', display:'flex', flexDirection:'column', gap:14, flex:1, minHeight:0, overflow:'hidden', paddingBottom:188}}>
          {/* Event meta card — replaces the title block now that title is in the header */}
          <div className="card" style={{padding:18}}>
            <div style={{display:'flex',alignItems:'center', gap:10, marginBottom:8}}>
              <span className="t-mono-cap c-subdued">14:00 – 14:45</span>
              <span style={{color:'var(--text-subdued)'}}>·</span>
              <span style={{display:'inline-flex',alignItems:'center',gap:4, color:'var(--text-secondary)', fontSize:14}}>
                {React.cloneElement(I.users, {size:14})}
                <span>3 Teilnehmer</span>
              </span>
              <span style={{color:'var(--text-subdued)'}}>·</span>
              <span style={{display:'inline-flex',alignItems:'center',gap:4, color:'var(--text-secondary)', fontSize:14}}>
                <span className="dot dot-success" style={{width:7,height:7}}/>
                <span>zugesagt</span>
              </span>
            </div>
            <div style={{fontSize:13, color:'var(--text-subdued)', lineHeight:1.45}}>
              Maya Acker, Stephan Bunz, Lara Wendel
            </div>
          </div>

          {/* Spoken-line card */}
          <div className="card-inset" style={{padding:'14px 16px'}}>
            <div className="t-mono-cap c-subdued" style={{marginBottom:6}}>EDITOR</div>
            <div style={{fontSize:16, lineHeight:1.5, color:'var(--text-secondary)', fontStyle:'normal'}}>
              „Wie ist das Review gelaufen? Was hat dich überrascht?"
            </div>
          </div>

          <div style={{flex:1}}/>

          {/* Timer — centered between the cards above and the action stack below */}
          <div style={{textAlign:'center'}}>
            <div className="mono tnum" style={{fontSize:48, fontWeight:400, letterSpacing:'-0.02em', marginBottom:4, color:'var(--text-primary)', lineHeight:1.05}}>
              02:18
            </div>
            <div className="c-subdued" style={{fontSize:12, letterSpacing:'0.04em', textTransform:'uppercase', fontWeight:500}}>{stateLabel}</div>
          </div>

          <div style={{flex:1}}/>
        </div>

        {/* Sticky bottom: "Frage stellen" sits just above the action stack. */}
        <div className="bottom-stack">
          <button className="btn btn-ghost btn-full" style={{justifyContent:'center', color:'var(--text-link)', height:32, marginBottom:-2}}>
            {React.cloneElement(I.question, {size:14})}
            <span style={{marginLeft:6}}>Frage stellen</span>
          </button>
          <div style={{display:'flex', gap:8}}>
            <button className="btn btn-secondary" style={{flex:1, height:44}}>Überspringen</button>
            <button className="btn btn-secondary" style={{flex:1, height:44}}>Ich bin fertig</button>
          </div>
          <button className="btn btn-primary btn-full btn-lg">Weiter</button>
        </div>

        <TabBar active="abend"/>
      </div>
      <HomeIndicator/>
    </div>
  );
};

const DayOverview = ({ variant = "full" }) => {
  // variant: "full" | "empty" | "dense"
  const events = variant === "empty" ? [] :
    variant === "dense" ? [
      { time: "09:00", dur: "30 m", title: "Standup", count: 6, rsvp: "success" },
      { time: "09:30", dur: "60 m", title: "1:1 mit Maya", count: 2, rsvp: "success" },
      { time: "10:30", dur: "45 m", title: "Architecture Review", count: 5, rsvp: "warn" },
      { time: "11:30", dur: "30 m", title: "Customer call — Kestrel", count: 4, rsvp: "link" },
      { time: "12:00", dur: "60 m", title: "Lunch & Learn", count: 12, rsvp: "subdued" },
      { time: "14:00", dur: "45 m", title: "Quartals-Review mit Stephan", count: 3, rsvp: "success" },
      { time: "15:00", dur: "30 m", title: "Hiring sync", count: 3, rsvp: "warn" },
    ] : [
      { time: "10:00", dur: "30 m", title: "1:1 mit Maya", count: 2, rsvp: "success" },
      { time: "13:30", dur: "60 m", title: "Customer call — Kestrel", count: 4, rsvp: "link" },
      { time: "14:00", dur: "45 m", title: "Quartals-Review mit Stephan", count: 3, rsvp: "success" },
    ];
  const allDay = variant === "full" ? [{ title: "Eltern-Abend (Lina)" }] : [];

  return (
    <div className="iphone vd-frame">
      <StatusBar />
      <div className="screen">
        <FlowHeader title="Abend" hasProgress={false} />

        <div className="screen-body scroll" style={{paddingTop:0}}>
          <div style={{padding:'0 0 12px'}}>
            <div className="t-body c-secondary" style={{fontSize:16, lineHeight:1.45}}>
              Bereit für die Abend-Reflexion? Geh die Termine deines Tages der Reihe nach durch.
            </div>
          </div>

          <div style={{display:'flex',alignItems:'center',justifyContent:'space-between', marginBottom:16}}>
            <div className="datepick">
              {React.cloneElement(I.calendar, {size:16})}
              <span>Heute · Di, 30. April</span>
              {React.cloneElement(I.chevronD, {size:14})}
            </div>
            <span className="t-mono-cap c-subdued">{events.length} TERMINE</span>
          </div>

          {allDay.length > 0 && (
            <>
              <div className="sec-h">Ganztägig</div>
              <div style={{display:'flex',flexDirection:'column',gap:6, marginBottom:16}}>
                {allDay.map((e, i) => (
                  <div key={i} className="allday-row">
                    <span className="icon">{React.cloneElement(I.sunHorizon, {size:16})}</span>
                    <span className="title">{e.title}</span>
                  </div>
                ))}
              </div>
            </>
          )}

          {events.length > 0 && (
            <>
              <div className="sec-h">Mit Uhrzeit</div>
              <div style={{display:'flex',flexDirection:'column',gap:6}}>
                {events.map((e, i) => (
                  <div key={i} className={`event-row rsvp-${e.rsvp}`}>
                    <div className="time">
                      <div>{e.time}</div>
                      <div style={{fontSize:11, color:'var(--text-subdued)'}}>{e.dur}</div>
                    </div>
                    <div className="bar"/>
                    <div className="body">
                      <div className="title">{e.title}</div>
                      <div className="meta">{e.count} Teilnehmer</div>
                    </div>
                  </div>
                ))}
              </div>
            </>
          )}

          {events.length === 0 && (
            <div style={{textAlign:'center', padding:'48px 24px', color:'var(--text-subdued)'}}>
              <div style={{display:'flex',justifyContent:'center', marginBottom:12}}>
                {React.cloneElement(I.calendar, {size:32, stroke:1.4})}
              </div>
              <div style={{fontSize:15}}>Keine zugesagten Termine.</div>
              <div style={{fontSize:13, marginTop:4}}>Wähle einen anderen Tag oder mach eine Drive-by-Aufnahme.</div>
            </div>
          )}

          <div style={{height:120}}/>
        </div>

        {/* Sticky CTA */}
        <div style={{position:'absolute', left:0, right:0, bottom:84, padding:'12px 16px 16px', background:'linear-gradient(to bottom, transparent, var(--surface) 30%)'}}>
          <button className="btn btn-primary btn-full btn-lg" disabled={events.length === 0} style={events.length===0?{opacity:0.4}:{}}>
            {events.length === 0 ? "Keine Termine heute" : `Sitzung starten (${events.length} Termine)`}
          </button>
        </div>

        <TabBar active="abend"/>
      </div>
      <HomeIndicator/>
    </div>
  );
};

const DoneCard = ({ withSummary = true }) => (
  <div className="iphone vd-frame">
    <StatusBar />
    <div className="screen">
      <FlowHeader title="Sitzung abgeschlossen" hasProgress={false} />
      <div style={{flex:1, display:'flex', flexDirection:'column', alignItems:'center', padding:'8px 32px 0', textAlign:'center'}}>
        <div style={{color:'var(--status-success)', marginBottom:24}}>
          {I.checkCircle({size:44})}
        </div>
        {withSummary && (
          <div className="c-secondary" style={{fontSize:16, lineHeight:1.5, marginBottom:20}}>
            5 Termine durchgegangen, 3 Aufgaben übernommen.
          </div>
        )}
        <div className="mono t-mono-cap c-subdued" style={{marginBottom:8, opacity:0.7}}>
          ses_2026-04-30_a7f3c1
        </div>
      </div>

      <div style={{padding:'0 16px 16px'}}>
        <button className="btn btn-primary btn-full btn-lg">Neue Sitzung</button>
      </div>

      <TabBar active="abend"/>
    </div>
    <HomeIndicator/>
  </div>
);

Object.assign(window, { Walkthrough, DayOverview, DoneCard });
