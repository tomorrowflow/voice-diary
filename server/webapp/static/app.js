// ============================================================
// app.js — Client-side logic for the transcript review page.
// Expects these globals from review.html <script> block:
//   TRANSCRIPT_ID, TRANSCRIPT_DATE, TRANSCRIPT_AUTHOR,
//   rawTranscript, entities, activeEntityIdx
// ============================================================

// --- Field compat helpers (server sends snake_case) ---
function eType(ent) { return ent.entity_type || ent.type || 'TERM'; }
function eOriginal(ent) { return ent.original_text || ent.originalText || ''; }
function eMatchType(ent) { return ent.match_type || ent.matchType || 'exact'; }
function eDictId(ent) { return ent.dictionary_id ?? ent.dictionaryId ?? null; }

// Store current transcript date for cross-tab navigation (e.g. Harvest)
if (typeof TRANSCRIPT_DATE !== 'undefined' && TRANSCRIPT_DATE) {
  sessionStorage.setItem('lastTranscriptDate', TRANSCRIPT_DATE);
}

// ============================================================
// MODAL DIALOGS
// ============================================================

var modalResolveFn = null;

function showModal(header, bodyHtml, buttons, opts) {
  opts = opts || {};
  document.getElementById('modalHeader').textContent = header;
  document.getElementById('modalHeader').className = 'modal-header' + (opts.danger ? ' danger' : '');
  document.getElementById('modalBody').innerHTML = bodyHtml;
  var footerHtml = '';
  for (var i = 0; i < buttons.length; i++) {
    var b = buttons[i];
    footerHtml += '<button class="btn-sm ' + (b.cls || 'btn btn-secondary') + '" onclick="resolveModal(' +
      (typeof b.value === 'string' ? "'" + b.value + "'" : b.value) + ')">' + b.label + '</button>';
  }
  document.getElementById('modalFooter').innerHTML = footerHtml;
  document.getElementById('modalOverlay').classList.add('visible');
}

function resolveModal(value) {
  document.getElementById('modalOverlay').classList.remove('visible');
  if (modalResolveFn) { var fn = modalResolveFn; modalResolveFn = null; fn(value); }
}

document.addEventListener('keydown', function(e) {
  var overlay = document.getElementById('modalOverlay');
  if (!overlay || !overlay.classList.contains('visible')) return;
  if (e.key === 'Escape') resolveModal(null);
  if (e.key === 'Enter') {
    var btns = document.querySelectorAll('#modalFooter button:not(.btn-secondary)');
    if (btns.length) btns[btns.length - 1].click();
  }
});

function modalConfirm(title, message, opts) {
  opts = opts || {};
  return new Promise(function(resolve) {
    modalResolveFn = resolve;
    showModal(title, '<p>' + message + '</p>', [
      { label: 'Cancel', cls: 'btn btn-secondary', value: false },
      { label: opts.confirmLabel || 'Confirm', cls: opts.confirmCls || 'btn btn-primary', value: true }
    ], opts);
  });
}

function modalAlert(title, message, opts) {
  opts = opts || {};
  return new Promise(function(resolve) {
    modalResolveFn = resolve;
    showModal(title, '<p>' + message + '</p>', [
      { label: 'OK', cls: opts.cls || 'btn btn-secondary', value: true }
    ], opts);
  });
}

// ============================================================
// RENDER
// ============================================================

function render() {
  renderTranscript();
  renderEntityList();
  updateStats();
}

function extendBtnsLeft(i) {
  return '<span class="inline-extend-btns">'
    + '<span class="extend-group">'
    + '<button class="btn-extend-inline" onclick="event.stopPropagation(); extendEntity(' + i + ', \'left\')" title="Extend left">\u2039</button>'
    + '<button class="btn-extend-inline" onclick="event.stopPropagation(); shrinkEntity(' + i + ', \'left\')" title="Shrink left">\u203A</button>'
    + '</span>'
    + '</span>';
}
function extendBtnsRight(i) {
  return '<span class="inline-extend-btns">'
    + '<span class="extend-group">'
    + '<button class="btn-extend-inline" onclick="event.stopPropagation(); shrinkEntity(' + i + ', \'right\')" title="Shrink right">\u2039</button>'
    + '<button class="btn-extend-inline" onclick="event.stopPropagation(); extendEntity(' + i + ', \'right\')" title="Extend right">\u203A</button>'
    + '</span>'
    + '</span>';
}

function renderPlainText(from, to) {
  // Render a plain-text range, highlighting inline edits and fluency issues
  var editsInRange = inlineEdits.filter(function(ed) {
    return ed.start < to && ed.end > from;
  }).sort(function(a, b) { return a.start - b.start; });

  var fluencyInRange = fluencyIssues.filter(function(f) {
    return f.start < to && f.end > from;
  });

  if (editsInRange.length === 0 && fluencyInRange.length === 0) {
    return '<span class="plain-text" data-start="' + from + '" data-end="' + to + '">'
      + escapeHtml(rawTranscript.substring(from, to)) + '</span>';
  }

  // Build a list of breakpoints to split the range into segments
  var points = [from, to];
  editsInRange.forEach(function(ed) {
    points.push(Math.max(ed.start, from), Math.min(ed.end, to));
  });
  fluencyInRange.forEach(function(f) {
    points.push(Math.max(f.start, from), Math.min(f.end, to));
  });
  // Deduplicate and sort
  points = points.filter(function(v, i, a) { return a.indexOf(v) === i; }).sort(function(a, b) { return a - b; });

  var html = '<span class="plain-text" data-start="' + from + '" data-end="' + to + '">';
  for (var pi = 0; pi < points.length - 1; pi++) {
    var segStart = points[pi];
    var segEnd = points[pi + 1];
    if (segStart >= segEnd) continue;

    // Check if this segment falls inside an inline edit
    var edit = null;
    for (var ei = 0; ei < editsInRange.length; ei++) {
      var ed = editsInRange[ei];
      if (segStart >= Math.max(ed.start, from) && segEnd <= Math.min(ed.end, to)) {
        edit = ed;
        break;
      }
    }

    // Check if this segment falls inside a fluency issue
    var fluency = null;
    for (var fi = 0; fi < fluencyInRange.length; fi++) {
      var f = fluencyInRange[fi];
      if (segStart >= Math.max(f.start, from) && segEnd <= Math.min(f.end, to)) {
        fluency = f;
        break;
      }
    }

    var segText = escapeHtml(rawTranscript.substring(segStart, segEnd));

    if (edit) {
      var tooltip = edit.source === 'llm'
        ? 'was: ' + escapeHtml(edit.oldWord) + ' \u2014 LLM: ' + escapeHtml(edit.reason || 'contextual fix')
        : 'was: ' + escapeHtml(edit.oldWord);
      var cls = 'inline-edited' + (fluency ? ' disfluent' : '');
      html += '<span class="' + cls + '" title="' + tooltip + '">' + segText + '</span>';
    } else if (fluency) {
      var catLabels = {
        incomplete: 'Incomplete sentence',
        false_start: 'False start',
        topic_switch: 'Topic switch',
        filler_heavy: 'Filler-heavy',
        run_on: 'Run-on sentence',
        broken_syntax: 'Broken syntax'
      };
      var label = catLabels[fluency.category] || fluency.category;
      var ftip = label + (fluency.note ? ': ' + escapeHtml(fluency.note) : '');
      html += '<span class="disfluent" title="' + ftip + '">' + segText + '</span>';
    } else {
      html += segText;
    }
  }
  html += '</span>';
  return html;
}

function renderTranscript() {
  const el = document.getElementById('transcript');
  if (!el) return;
  let html = '';
  let pos = 0;

  for (let i = 0; i < entities.length; i++) {
    const ent = entities[i];
    if (ent.start > pos) {
      html += renderPlainText(pos, ent.start);
    }
    const isActive = activeEntityIdx === i;
    const classes = 'entity-highlight ' + ent.status + (isActive ? ' active' : '');
    var extL = isActive ? extendBtnsLeft(i) : '';
    var extR = isActive ? extendBtnsRight(i) : '';

    if (ent.status === 'auto-matched' && eOriginal(ent) !== ent.canonical) {
      html += '<span class="' + classes + '" data-idx="' + i + '" data-start="' + ent.start + '" data-end="' + ent.end + '" onclick="selectEntity(' + i + ')">';
      html += extL;
      html += '<s style="opacity:0.5">' + escapeHtml(eOriginal(ent)) + '</s>';
      html += '<span class="correction-arrow"> &rarr; </span>';
      html += '<span class="corrected-text">' + escapeHtml(ent.canonical) + '</span>';
      html += extR;
      html += '</span>';
    } else if (ent.status === 'suggested') {
      html += '<span class="' + classes + '" data-idx="' + i + '" data-start="' + ent.start + '" data-end="' + ent.end + '" onclick="selectEntity(' + i + ')">';
      html += extL + escapeHtml(eOriginal(ent));
      html += extR;
      html += '</span>';
    } else if (ent.status === 'ambiguous') {
      html += '<span class="' + classes + '" data-idx="' + i + '" data-start="' + ent.start + '" data-end="' + ent.end + '" onclick="selectEntity(' + i + ')">';
      html += extL + escapeHtml(eOriginal(ent));
      html += extR;
      html += '</span>';
    } else if (ent.status === 'dismissed') {
      html += '<span class="' + classes + '" data-start="' + ent.start + '" data-end="' + ent.end + '">'
        + escapeHtml(rawTranscript.substring(ent.start, ent.end)) + '</span>';
    } else {
      html += '<span class="' + classes + '" data-idx="' + i + '" data-start="' + ent.start + '" data-end="' + ent.end + '" onclick="selectEntity(' + i + ')">'
        + extL + escapeHtml(eOriginal(ent)) + extR + '</span>';
    }
    pos = ent.end;
  }
  if (pos < rawTranscript.length) {
    html += renderPlainText(pos, rawTranscript.length);
  }
  el.innerHTML = html;
}

function renderEntityList() {
  const el = document.getElementById('entity-list');
  if (!el) return;

  // Build flat list with original indices
  var order = { ambiguous: 0, suggested: 1, 'new-entity': 2, 'auto-matched': 3, dismissed: 4 };
  var indexed = entities.map(function(ent, idx) { return { ent: ent, idx: idx }; });
  indexed.sort(function(a, b) {
    var sa = order[a.ent.status] !== undefined ? order[a.ent.status] : 3;
    var sb = order[b.ent.status] !== undefined ? order[b.ent.status] : 3;
    if (sa !== sb) return sa - sb;
    return a.ent.start - b.ent.start;
  });

  el.innerHTML = indexed.map(function(item) {
    var ent = item.ent;
    var idx = item.idx;
    var isActive = activeEntityIdx === idx;
    var badgeClass = 'badge-' + eType(ent).toLowerCase();
    var mt = eMatchType(ent);
    var matchClass = mt === 'llm' ? 'match-llm'
      : mt === 'manual' ? 'match-new'
      : mt === 'fuzzy' ? 'match-suggested'
      : mt === 'first_name' && ent.status === 'ambiguous' ? 'match-ambiguous'
      : 'match-exact';
    var matchLabel = mt === 'llm' ? 'LLM'
      : mt === 'manual' ? 'manual'
      : mt === 'exact' ? 'exact'
      : mt === 'fuzzy' ? 'suggested'
      : mt === 'first_name' ? 'first name'
      : mt === 'disambiguated' ? 'disambiguated'
      : 'variation';

    var cardHtml = '<div class="entity-card ' + ent.status + (isActive ? ' active' : '')
      + '" data-idx="' + idx + '"'
      + ' onclick="selectEntity(' + idx + ')">';

    // Header with extend/shrink buttons
    cardHtml += '<div class="entity-card-header">';
    cardHtml += '<span class="entity-header-text">';
    cardHtml += '<span class="extend-group">';
    cardHtml += '<button class="btn-extend" onclick="event.stopPropagation(); extendEntity(' + idx + ', \'left\')" title="Extend left">\u2039</button>';
    cardHtml += '<button class="btn-extend" onclick="event.stopPropagation(); shrinkEntity(' + idx + ', \'left\')" title="Shrink left">\u203A</button>';
    cardHtml += '</span>';
    cardHtml += '<span class="entity-original">'
      + escapeHtml(eOriginal(ent) !== ent.canonical ? eOriginal(ent) : ent.canonical) + '</span>';
    cardHtml += '<span class="extend-group">';
    cardHtml += '<button class="btn-extend" onclick="event.stopPropagation(); shrinkEntity(' + idx + ', \'right\')" title="Shrink right">\u2039</button>';
    cardHtml += '<button class="btn-extend" onclick="event.stopPropagation(); extendEntity(' + idx + ', \'right\')" title="Extend right">\u203A</button>';
    cardHtml += '</span>';
    cardHtml += '</span>';
    cardHtml += '<span class="entity-type-badge ' + badgeClass + '">' + eType(ent) + '</span>';
    cardHtml += '</div>';

    // Match info
    cardHtml += '<div class="entity-match-info">';
    cardHtml += '<span class="match-type ' + matchClass + '">' + matchLabel + '</span>';
    if (ent.llm_validated && mt !== 'llm') {
      cardHtml += '<span class="match-type match-llm">LLM</span>';
    }
    if (ent.role) cardHtml += ' &middot; ' + escapeHtml(ent.role);
    if (eOriginal(ent) !== ent.canonical && ent.status !== 'ambiguous') {
      cardHtml += ' &middot; <span style="color:#3fb950">&rarr; ' + escapeHtml(ent.canonical) + '</span>';
    }
    if (ent.llm_reason) {
      cardHtml += '<div class="llm-reason">' + escapeHtml(ent.llm_reason) + '</div>';
    }
    cardHtml += '</div>';

    // Ambiguous: radio buttons for candidates
    if (ent.status === 'ambiguous' && ent.candidates && ent.candidates.length > 0) {
      cardHtml += '<div class="entity-candidates">';
      ent.candidates.forEach(function(candidate) {
        cardHtml += '<label>'
          + '<input type="radio" name="disambig-' + idx + '" value="' + candidate.id + '" '
          + 'onclick="event.stopPropagation(); disambiguateEntity(' + idx + ', '
          + candidate.id + ', \'' + escapeHtml(candidate.canonical).replace(/'/g, "\\'") + '\')">'
          + escapeHtml(candidate.canonical)
          + '<span class="candidate-role">' + escapeHtml(candidate.role || '') + '</span>'
          + '</label>';
      });
      // None of these option
      cardHtml += '<label>'
        + '<input type="radio" name="disambig-' + idx + '" value="none" '
        + 'onclick="event.stopPropagation(); dismissEntity(' + idx + ')">'
        + 'None of these'
        + '<span class="candidate-role">dismiss to mark as new entity</span>'
        + '</label>';
      cardHtml += '</div>';
    }

    // Correction input (not for ambiguous)
    if (ent.status !== 'ambiguous') {
      cardHtml += '<div class="entity-correction">';
      cardHtml += '<input type="text" value="' + escapeHtml(ent.canonical) + '" '
        + 'oninput="onCanonicalInput(' + idx + ', this)" '
        + 'onchange="updateCanonical(' + idx + ', this.value)" '
        + 'onkeydown="onCanonicalKeydown(event, ' + idx + ')" '
        + 'onfocus="onCanonicalInput(' + idx + ', this)" '
        + 'onclick="event.stopPropagation()" '
        + 'autocomplete="off">';
      cardHtml += '<select onchange="updateType(' + idx + ', this.value)" onclick="event.stopPropagation()">';
      ['PERSON','ORGANIZATION','TERM','CONCEPT','TECHNOLOGY','ROLE','LOCATION','PROJECT','EVENT'].forEach(function(t) {
        cardHtml += '<option value="' + t + '"' + (t === eType(ent) ? ' selected' : '') + '>' + t + '</option>';
      });
      cardHtml += '</select></div>';
    }

    // Actions
    cardHtml += '<div class="entity-actions">';
    if (ent.status === 'suggested') {
      cardHtml += '<button class="btn-sm btn-confirm" onclick="event.stopPropagation(); confirmEntity(' + idx + ')">Confirm</button>';
      cardHtml += '<button class="btn-sm btn-dismiss" onclick="event.stopPropagation(); dismissEntity(' + idx + ')">Dismiss</button>';
    } else if (ent.status === 'new-entity') {
      cardHtml += '<button class="btn-sm btn-dismiss" onclick="event.stopPropagation(); removeEntity(' + idx + ')">Remove</button>';
    } else if (ent.status === 'auto-matched') {
      cardHtml += '<button class="btn-sm btn-dismiss" onclick="event.stopPropagation(); dismissEntity(' + idx + ')">Not an entity</button>';
    } else if (ent.status === 'dismissed') {
      cardHtml += '<button class="btn-sm btn-confirm" onclick="event.stopPropagation(); restoreEntity(' + idx + ')">Restore</button>';
    }
    // ambiguous has radio buttons instead
    cardHtml += '</div>';

    cardHtml += '</div>';
    return cardHtml;
  }).join('');
}

function updateStats() {
  var auto = entities.filter(function(e) { return e.status === 'auto-matched'; }).length;
  var suggested = entities.filter(function(e) { return e.status === 'suggested'; }).length;
  var ambiguous = entities.filter(function(e) { return e.status === 'ambiguous'; }).length;
  var newE = entities.filter(function(e) { return e.status === 'new-entity'; }).length;

  var autoEl = document.getElementById('auto-count');
  var suggestedEl = document.getElementById('suggested-count');
  var newEl = document.getElementById('new-count');
  var unresolvedEl = document.getElementById('unresolved-count');

  if (autoEl) autoEl.textContent = auto;
  if (suggestedEl) suggestedEl.textContent = suggested;
  if (newEl) newEl.textContent = newE;
  if (unresolvedEl) unresolvedEl.textContent = suggested + ambiguous;

  var corrections = entities.filter(function(e) {
    return eOriginal(e) !== e.canonical && e.status !== 'dismissed';
  }).length;
  var newEntities = entities.filter(function(e) { return e.status === 'new-entity'; }).length;
  var totalChanges = corrections + newEntities;

  var summaryEl = document.getElementById('correction-summary');
  if (summaryEl) {
    summaryEl.textContent = totalChanges > 0
      ? corrections + ' correction' + (corrections !== 1 ? 's' : '')
        + ', ' + newEntities + ' new entit' + (newEntities !== 1 ? 'ies' : 'y')
        + (ambiguous > 0 ? ', ' + ambiguous + ' ambiguous' : '')
        + ' \u2014 will be saved to dictionary'
      : 'No changes' + (ambiguous > 0 ? ' (' + ambiguous + ' ambiguous)' : '');
  }

  // Fluency stats
  var fluencyCount = fluencyIssues.length;
  var fluencyStat = document.getElementById('fluency-stat');
  var fluencyEl = document.getElementById('fluency-count');
  if (fluencyStat) {
    fluencyStat.style.display = fluencyCount > 0 ? '' : 'none';
  }
  if (fluencyEl) {
    fluencyEl.textContent = fluencyCount;
  }
}

// ============================================================
// INTERACTIONS
// ============================================================

function selectEntity(idx) {
  activeEntityIdx = idx;
  render();

  // Scroll transcript panel to the highlighted entity
  var highlight = document.querySelector('.entity-highlight[data-idx="' + idx + '"]');
  if (highlight) {
    highlight.scrollIntoView({ behavior: 'smooth', block: 'center' });
  }

  // Scroll sidebar to the corresponding card
  // Double-rAF ensures layout is fully flushed after innerHTML (needed for Safari)
  requestAnimationFrame(function() {
    requestAnimationFrame(function() {
      scrollSidebarToActiveCard();
    });
  });
}

function scrollSidebarToActiveCard() {
  var card = document.querySelector('.entity-card.active');
  if (!card) return;
  card.scrollIntoView({ behavior: 'instant', block: 'center' });
}

function updateCanonical(idx, value) {
  entities[idx].canonical = value;
  render();
}

function updateType(idx, type) {
  entities[idx].entity_type = type;
  render();
}

function confirmEntity(idx) {
  entities[idx].status = 'auto-matched';
  render();
}

function dismissEntity(idx) {
  var ent = entities[idx];
  // For ambiguous entities, also dismiss other ambiguous entities at the same position
  // (they are logically linked — same text, different candidates)
  if (ent.status === 'ambiguous') {
    var original = eOriginal(ent);
    entities.forEach(function(e) {
      if (e.status === 'ambiguous' && eOriginal(e) === original) {
        e._previousStatus = e.status;
        e.status = 'dismissed';
      }
    });
  } else {
    ent._previousStatus = ent.status;
    ent.status = 'dismissed';
  }
  render();
}

function removeEntity(idx) {
  entities.splice(idx, 1);
  if (activeEntityIdx === idx) {
    activeEntityIdx = null;
  } else if (activeEntityIdx !== null && activeEntityIdx > idx) {
    activeEntityIdx--;
  }
  render();
}

function restoreEntity(idx) {
  var ent = entities[idx];
  ent.status = ent._previousStatus || 'suggested';
  delete ent._previousStatus;
  render();
}

function extendEntity(idx, direction) {
  var ent = entities[idx];
  var newStart = ent.start;
  var newEnd = ent.end;

  if (direction === 'left') {
    var pos = ent.start - 1;
    while (pos >= 0 && /\s/.test(rawTranscript[pos])) pos--;
    if (pos < 0) return;
    while (pos >= 0 && !/\s/.test(rawTranscript[pos])) pos--;
    newStart = pos + 1;
  } else {
    var pos = ent.end;
    while (pos < rawTranscript.length && /\s/.test(rawTranscript[pos])) pos++;
    if (pos >= rawTranscript.length) return;
    while (pos < rawTranscript.length && !/\s/.test(rawTranscript[pos])) pos++;
    newEnd = pos;
  }

  for (var i = 0; i < entities.length; i++) {
    if (i === idx) continue;
    if (entities[i].status === 'dismissed') continue;
    if (newStart < entities[i].end && newEnd > entities[i].start) return;
  }

  ent.start = newStart;
  ent.end = newEnd;
  ent.original_text = rawTranscript.substring(newStart, newEnd);
  render();
}

function shrinkEntity(idx, side) {
  var ent = entities[idx];
  var text = rawTranscript.substring(ent.start, ent.end);

  // Must have at least 2 words to shrink
  var words = text.split(/\s+/);
  if (words.length < 2) return;

  if (side === 'left') {
    // Remove the first word + following whitespace
    var pos = ent.start;
    while (pos < ent.end && !/\s/.test(rawTranscript[pos])) pos++;
    while (pos < ent.end && /\s/.test(rawTranscript[pos])) pos++;
    ent.start = pos;
  } else {
    // Remove the last word + preceding whitespace
    var pos = ent.end - 1;
    while (pos > ent.start && !/\s/.test(rawTranscript[pos])) pos--;
    while (pos > ent.start && /\s/.test(rawTranscript[pos])) pos--;
    ent.end = pos + 1;
  }

  ent.original_text = rawTranscript.substring(ent.start, ent.end);
  render();
}

function disambiguateEntity(idx, chosenId, chosenCanonical) {
  var original = eOriginal(entities[idx]);
  entities.forEach(function(e) {
    if (eOriginal(e) === original && e.status === 'ambiguous') {
      e.canonical = chosenCanonical;
      e.dictionary_id = chosenId;
      e.status = 'auto-matched';
      e.match_type = 'disambiguated';
      e.confidence = 'high';
      e._disambiguated = {
        original: original,
        chosen_id: chosenId,
        chosen_canonical: chosenCanonical
      };
    }
  });
  render();
}

function btnWorking(btn, text) {
  btn.disabled = true;
  btn.classList.add('working');
  btn.textContent = text;
}

function btnDone(btn, text, resetLabel, resetDelay) {
  btn.classList.remove('working');
  btn.classList.add('done');
  btn.textContent = text;
  if (resetLabel) {
    setTimeout(function() {
      btn.classList.remove('done');
      btn.textContent = resetLabel;
      btn.disabled = false;
    }, resetDelay || 1500);
  }
}

function btnReset(btn, label) {
  btn.classList.remove('working', 'done');
  btn.disabled = false;
  btn.textContent = label;
}

async function saveDraft() {
  var activeEntities = entities.filter(function(e) { return e.status !== 'dismissed'; });
  var corrections = activeEntities.filter(function(e) { return eOriginal(e) !== e.canonical; });

  // Build corrected transcript
  var corrected = rawTranscript;
  var sorted = corrections.slice().sort(function(a, b) { return b.start - a.start; });
  sorted.forEach(function(ent) {
    corrected = corrected.substring(0, ent.start) + ent.canonical + corrected.substring(ent.end);
  });

  var btn = document.getElementById('save-btn');
  btnWorking(btn, 'Saving...');

  try {
    var resp = await fetch('/api/transcripts/' + TRANSCRIPT_ID + '/save', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        corrected_transcript: corrected,
        raw_text: rawTranscript,
        entities: entities,
        text_edits: inlineEdits.map(function(ed) {
          return { oldWord: ed.oldWord, newWord: ed.newWord };
        }),
      }),
    });
    var result = await resp.json();
    if (result.status === 'saved') {
      btnDone(btn, 'Saved', 'Save', 1500);
    } else {
      modalAlert('Save Failed', 'Error: ' + JSON.stringify(result), { danger: true });
      btnReset(btn, 'Save');
    }
  } catch (err) {
    modalAlert('Network Error', err.message, { danger: true });
    btnReset(btn, 'Save');
  }
}

// ============================================================
// RESET
// ============================================================

async function resetTranscript() {
  var confirmed = await modalConfirm(
    'Reset Transcript',
    'This will clear all saved corrections, entities, and markdown. The transcript will be reprocessed from scratch.',
    { danger: true, confirmLabel: 'Reset', confirmCls: 'btn btn-danger' }
  );
  if (!confirmed) return;

  var btn = document.getElementById('reset-btn');
  btnWorking(btn, 'Resetting...');

  try {
    var resp = await fetch('/api/transcripts/' + TRANSCRIPT_ID + '/reset', {
      method: 'POST',
    });
    var result = await resp.json();
    if (result.status === 'reset') {
      window.location.reload();
    } else {
      modalAlert('Reset Failed', 'Error: ' + JSON.stringify(result), { danger: true });
      btnReset(btn, 'Reset');
    }
  } catch (err) {
    modalAlert('Network Error', err.message, { danger: true });
    btnReset(btn, 'Reset');
  }
}

// ============================================================
// SUBMIT
// ============================================================

async function submitReview() {
  var activeEntities = entities.filter(function(e) { return e.status !== 'dismissed'; });
  var dismissed = entities.filter(function(e) { return e.status === 'dismissed'; });
  var corrections = activeEntities.filter(function(e) { return eOriginal(e) !== e.canonical; });

  // Check for unresolved ambiguous entities
  var ambiguous = activeEntities.filter(function(e) { return e.status === 'ambiguous'; });
  if (ambiguous.length > 0) {
    modalAlert('Unresolved Entities',
      'Please resolve all ambiguous entities (purple) before submitting.<br><br>'
      + ambiguous.length + ' ambiguous entit' + (ambiguous.length > 1 ? 'ies' : 'y') + ' remaining.');
    return;
  }

  // Build corrected transcript
  var corrected = rawTranscript;
  var sorted = corrections.slice().sort(function(a, b) { return b.start - a.start; });
  sorted.forEach(function(ent) {
    corrected = corrected.substring(0, ent.start) + ent.canonical + corrected.substring(ent.end);
  });

  var payload = {
    corrected_transcript: corrected,
    date: TRANSCRIPT_DATE,
    author: TRANSCRIPT_AUTHOR,
    entities: activeEntities.map(function(e) {
      var obj = {
        text: e.canonical,
        type: eType(e),
        original: eOriginal(e),
        is_correction: eOriginal(e) !== e.canonical,
        match_type: eMatchType(e),
      };
      var did = eDictId(e);
      if (did) obj.dictionary_id = did;
      return obj;
    }),
    new_variations: corrections
      .filter(function(e) { return eDictId(e); })
      .map(function(e) {
        return {
          original: eOriginal(e),
          canonical: e.canonical,
          type: eType(e),
          source: e.source,
          dictionary_id: eDictId(e),
        };
      }),
    new_entities: activeEntities
      .filter(function(e) { return e.status === 'new-entity'; })
      .map(function(e) {
        return {
          text: e.canonical,
          type: eType(e),
          source: e.source || (eType(e) === 'PERSON' ? 'person' : 'term'),
        };
      }),
    disambiguated: activeEntities
      .filter(function(e) { return e._disambiguated; })
      .map(function(e) { return e._disambiguated; }),
    dismissed: dismissed.map(function(e) {
      return {
        original: eOriginal(e),
        canonical: e.canonical,
        type: eType(e),
      };
    }),
    text_edits: inlineEdits.map(function(ed) {
      return { oldWord: ed.oldWord, newWord: ed.newWord };
    }),
  };

  var btn = document.getElementById('submit-btn');
  btnWorking(btn, 'Saving...');

  // Add skip_n8n flag — processing is now done in-app
  payload.skip_n8n = true;

  try {
    var resp = await fetch('/api/transcripts/' + TRANSCRIPT_ID + '/submit', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    var result = await resp.json();
    if (result.status === 'submitted') {
      btnDone(btn, 'Saved');
      setTimeout(function() {
        window.location.href = '/process/' + TRANSCRIPT_ID;
      }, 500);
    } else {
      modalAlert('Submit Failed', 'Error: ' + JSON.stringify(result), { danger: true });
      btnReset(btn, 'Save & Process \u2192');
    }
  } catch (err) {
    modalAlert('Network Error', err.message, { danger: true });
    btnReset(btn, 'Save & Process \u2192');
  }
}

// ============================================================
// DICTIONARY LOOKUP (for duplicate checking)
// ============================================================

var dictionary = null; // { persons: [...], terms: [...] }

function loadDictionary() {
  fetch('/api/dictionary')
    .then(function(r) { return r.json(); })
    .then(function(data) {
      // asyncpg returns json columns as raw strings — parse them
      (data.persons || []).forEach(function(p) {
        if (typeof p.variations === 'string') {
          try { p.variations = JSON.parse(p.variations); } catch(e) { p.variations = []; }
        }
      });
      (data.terms || []).forEach(function(t) {
        if (typeof t.variations === 'string') {
          try { t.variations = JSON.parse(t.variations); } catch(e) { t.variations = []; }
        }
      });
      dictionary = data;
    })
    .catch(function() { dictionary = { persons: [], terms: [] }; });
}

function findDictionaryMatches(text) {
  if (!dictionary) return [];
  var matches = [];
  var lower = text.toLowerCase();

  // Check persons
  (dictionary.persons || []).forEach(function(p) {
    var matched = false;
    if (p.canonical_name && p.canonical_name.toLowerCase() === lower) matched = true;
    if (!matched && p.variations) {
      p.variations.forEach(function(v) {
        var vText = typeof v === 'object' ? (v.variation || '') : v;
        if (vText.toLowerCase() === lower) matched = true;
      });
    }
    if (matched) {
      matches.push({
        source: 'person',
        id: p.id,
        canonical: p.canonical_name,
        type: 'PERSON',
        detail: [p.role, p.company].filter(Boolean).join(', '),
      });
    }
  });

  // Check terms
  (dictionary.terms || []).forEach(function(t) {
    var matched = false;
    if (t.canonical_term && t.canonical_term.toLowerCase() === lower) matched = true;
    if (!matched && t.variations) {
      t.variations.forEach(function(v) {
        var vText = typeof v === 'object' ? (v.variation || '') : v;
        if (vText.toLowerCase() === lower) matched = true;
      });
    }
    if (matched) {
      var catMap = {
        company: 'ORGANIZATION', department: 'ORGANIZATION',
        technology: 'TECHNOLOGY', project: 'PROJECT',
        location: 'LOCATION', event: 'EVENT', concept: 'CONCEPT',
      };
      matches.push({
        source: 'term',
        id: t.id,
        canonical: t.canonical_term,
        type: catMap[t.category] || 'TERM',
        detail: t.category || 'term',
      });
    }
  });

  return matches;
}

function addLinkedEntity(match) {
  if (!pendingSelection) return;

  var newEntity = {
    start: pendingSelection.start,
    end: pendingSelection.end,
    original_text: pendingSelection.text,
    canonical: match.canonical,
    entity_type: match.type,
    match_type: 'manual',
    confidence: 'high',
    status: 'auto-matched',
    dictionary_id: match.id,
    source: match.source,
    role: '',
    candidates: []
  };

  entities = entities.filter(function(e) {
    return !(e.status === 'dismissed' && e.start < newEntity.end && e.end > newEntity.start);
  });

  entities.push(newEntity);
  entities.sort(function(a, b) { return a.start - b.start; });

  var deduped = [];
  var lastEnd = -1;
  entities.forEach(function(d) {
    if (d.start >= lastEnd) { deduped.push(d); lastEnd = d.end; }
  });
  entities = deduped;

  hideSelectionPopup();
  window.getSelection().removeAllRanges();

  var newIdx = entities.findIndex(function(e) {
    return e.start === newEntity.start && e.end === newEntity.end;
  });
  activeEntityIdx = newIdx;
  render();
  requestAnimationFrame(function() {
    requestAnimationFrame(function() { scrollSidebarToActiveCard(); });
  });
}

// ============================================================
// MANUAL ENTITY SELECTION
// ============================================================

var pendingSelection = null;
var savedMultiWordSelection = null;

(function() {
  var transcriptEl = document.getElementById('transcript');
  if (!transcriptEl) return;

  transcriptEl.addEventListener('mouseup', function(e) {
    // Double-click mouseup: skip to let the dblclick handler take over.
    // detail=2 means this mouseup is the second click of a double-click.
    if (e.detail >= 2) return;

    var sel = window.getSelection();
    var text = sel.toString().trim();

    if (!text) {
      hideSelectionPopup();
      return;
    }

    // Don't trigger on active entity highlights
    var highlightEl = e.target.closest('.entity-highlight');
    if (highlightEl && !highlightEl.classList.contains('dismissed')) return;

    var range = sel.getRangeAt(0);
    var startOffset = resolveOffset(range.startContainer, range.startOffset);
    var endOffset = resolveOffset(range.endContainer, range.endOffset);

    if (startOffset === null || endOffset === null || startOffset >= endOffset) return;

    // Check overlap with active entities
    var overlaps = entities.some(function(ent) {
      return ent.status !== 'dismissed' && startOffset < ent.end && endOffset > ent.start;
    });
    if (overlaps) return;

    pendingSelection = {
      text: rawTranscript.substring(startOffset, endOffset),
      start: startOffset,
      end: endOffset
    };

    var popup = document.getElementById('selection-popup');
    var popupText = document.getElementById('selection-popup-text');
    popupText.textContent = '"' + pendingSelection.text + '"';

    // Check dictionary for existing matches
    var matchesEl = document.getElementById('selection-popup-matches');
    var dividerEl = document.getElementById('selection-popup-divider');
    var newlabelEl = document.getElementById('selection-popup-newlabel');
    var dictMatches = findDictionaryMatches(pendingSelection.text);

    matchesEl.innerHTML = '';
    if (dictMatches.length > 0) {
      matchesEl.classList.add('has-matches');
      dividerEl.classList.add('visible');
      newlabelEl.classList.add('visible');
      dictMatches.forEach(function(m, mi) {
        var btn = document.createElement('div');
        btn.className = 'selection-popup-match';
        btn.innerHTML = '<span class="match-badge badge-' + m.type.toLowerCase() + '">'
          + m.type + '</span>'
          + '<span class="match-canonical">' + escapeHtml(m.canonical) + '</span>'
          + (m.detail ? '<span class="match-detail">' + escapeHtml(m.detail) + '</span>' : '');
        btn.onclick = function(e) { e.stopPropagation(); addLinkedEntity(m); };
        matchesEl.appendChild(btn);
      });
    } else {
      matchesEl.classList.remove('has-matches');
      dividerEl.classList.remove('visible');
      newlabelEl.classList.remove('visible');
    }

    var rect = range.getBoundingClientRect();
    var panelRect = transcriptEl.closest('.transcript-panel').getBoundingClientRect();

    popup.style.left = Math.min(rect.left, panelRect.right - 320) + 'px';
    popup.style.top = (rect.bottom + window.scrollY + 8) + 'px';
    popup.classList.add('visible');
  });

  // Save multi-word selection before browser clears it on mousedown.
  // The dblclick handler checks savedMultiWordSelection instead of pendingSelection.
  transcriptEl.addEventListener('mousedown', function(e) {
    if (pendingSelection && /\s/.test(pendingSelection.text)) {
      savedMultiWordSelection = {
        start: pendingSelection.start,
        end: pendingSelection.end,
        text: pendingSelection.text
      };
    } else {
      savedMultiWordSelection = null;
    }
  });

  document.addEventListener('mousedown', function(e) {
    if (!e.target.closest('.selection-popup') && !e.target.closest('.transcript-text')) {
      hideSelectionPopup();
    }
  });
})();

function hideSelectionPopup() {
  var popup = document.getElementById('selection-popup');
  if (popup) popup.classList.remove('visible');
  pendingSelection = null;
}


function resolveOffset(node, localOffset) {
  var span = node.nodeType === Node.TEXT_NODE ? node.parentElement : node;
  while (span && !span.dataset.start) {
    span = span.parentElement;
    if (span && span.id === 'transcript') return null;
  }
  if (!span || !span.dataset.start) return null;
  var spanStart = parseInt(span.dataset.start);

  var charsBefore = 0;
  var walker = document.createTreeWalker(span, NodeFilter.SHOW_TEXT);
  var current;
  while (current = walker.nextNode()) {
    if (current === node) {
      return spanStart + charsBefore + localOffset;
    }
    charsBefore += current.textContent.length;
  }
  return spanStart + localOffset;
}

function addManualEntity(type) {
  if (!pendingSelection) return;

  var newEntity = {
    start: pendingSelection.start,
    end: pendingSelection.end,
    original_text: pendingSelection.text,
    canonical: pendingSelection.text,
    entity_type: type,
    match_type: 'manual',
    confidence: 'high',
    status: 'new-entity',
    dictionary_id: null,
    source: type === 'PERSON' ? 'person' : 'term',
    role: '',
    candidates: []
  };

  // Remove dismissed entities that overlap with the new entity's range
  entities = entities.filter(function(e) {
    return !(e.status === 'dismissed' && e.start < newEntity.end && e.end > newEntity.start);
  });

  entities.push(newEntity);
  entities.sort(function(a, b) { return a.start - b.start; });

  // Deduplicate
  var deduped = [];
  var lastEnd = -1;
  entities.forEach(function(d) {
    if (d.start >= lastEnd) {
      deduped.push(d);
      lastEnd = d.end;
    }
  });
  entities = deduped;

  hideSelectionPopup();
  window.getSelection().removeAllRanges();

  var newIdx = entities.findIndex(function(e) {
    return e.start === newEntity.start && e.end === newEntity.end;
  });
  activeEntityIdx = newIdx;
  render();

  requestAnimationFrame(function() {
    requestAnimationFrame(function() {
      scrollSidebarToActiveCard();
    });
  });
}

// ============================================================
// AUTOCOMPLETE ON CANONICAL INPUT
// ============================================================

var acActiveIdx = -1;  // keyboard-highlighted index in the dropdown
var acMatches = [];     // current autocomplete matches
var acEntityIdx = null; // which entity card the autocomplete is for

function searchDictionary(query) {
  if (!dictionary || query.length < 2) return [];
  var lower = query.toLowerCase();
  var results = [];

  (dictionary.persons || []).forEach(function(p) {
    var score = 0;
    var canon = p.canonical_name || '';
    if (canon.toLowerCase() === lower) { score = 100; }
    else if (canon.toLowerCase().indexOf(lower) === 0) { score = 80; }
    else if (canon.toLowerCase().indexOf(lower) >= 0) { score = 60; }
    else {
      (p.variations || []).forEach(function(v) {
        var vText = typeof v === 'object' ? (v.variation || '') : String(v);
        if (vText.toLowerCase().indexOf(lower) >= 0 && score < 40) score = 40;
      });
    }
    if (score > 0) {
      results.push({
        source: 'person', id: p.id, canonical: canon, type: 'PERSON',
        detail: [p.role, p.company].filter(Boolean).join(', '),
        score: score,
      });
    }
  });

  var catMap = {
    company: 'ORGANIZATION', department: 'ORGANIZATION',
    technology: 'TECHNOLOGY', project: 'PROJECT',
    location: 'LOCATION', event: 'EVENT', concept: 'CONCEPT',
  };
  (dictionary.terms || []).forEach(function(t) {
    var score = 0;
    var canon = t.canonical_term || '';
    if (canon.toLowerCase() === lower) { score = 100; }
    else if (canon.toLowerCase().indexOf(lower) === 0) { score = 80; }
    else if (canon.toLowerCase().indexOf(lower) >= 0) { score = 60; }
    else {
      (t.variations || []).forEach(function(v) {
        var vText = typeof v === 'object' ? (v.variation || '') : String(v);
        if (vText.toLowerCase().indexOf(lower) >= 0 && score < 40) score = 40;
      });
    }
    if (score > 0) {
      results.push({
        source: 'term', id: t.id, canonical: canon,
        type: catMap[t.category] || 'TERM',
        detail: t.category || 'term',
        score: score,
      });
    }
  });

  results.sort(function(a, b) { return b.score - a.score; });
  return results.slice(0, 8);
}

function highlightMatch(text, query) {
  if (!query) return escapeHtml(text);
  var idx = text.toLowerCase().indexOf(query.toLowerCase());
  if (idx < 0) return escapeHtml(text);
  return escapeHtml(text.substring(0, idx))
    + '<mark>' + escapeHtml(text.substring(idx, idx + query.length)) + '</mark>'
    + escapeHtml(text.substring(idx + query.length));
}

function showAutocomplete(inputEl, entityIdx, query) {
  var dropdown = document.getElementById('autocomplete-dropdown');
  acMatches = searchDictionary(query);
  acEntityIdx = entityIdx;
  acActiveIdx = -1;

  if (acMatches.length === 0) {
    hideAutocomplete();
    return;
  }

  dropdown.innerHTML = acMatches.map(function(m, i) {
    return '<div class="autocomplete-item" data-idx="' + i + '"'
      + ' onmousedown="event.preventDefault(); pickAutocomplete(' + i + ')">'
      + '<span class="ac-badge badge-' + m.type.toLowerCase() + '">' + m.type + '</span>'
      + '<span class="ac-text">'
      + '<span class="ac-canonical">' + highlightMatch(m.canonical, query) + '</span>'
      + (m.detail ? '<span class="ac-detail">' + escapeHtml(m.detail) + '</span>' : '')
      + '</span>'
      + '</div>';
  }).join('');

  // Position below the input
  var rect = inputEl.getBoundingClientRect();
  dropdown.style.left = rect.left + 'px';
  dropdown.style.top = (rect.bottom + 2) + 'px';
  dropdown.style.width = Math.max(rect.width, 250) + 'px';
  dropdown.classList.add('visible');
}

function hideAutocomplete() {
  var dropdown = document.getElementById('autocomplete-dropdown');
  if (dropdown) dropdown.classList.remove('visible');
  acMatches = [];
  acActiveIdx = -1;
  acEntityIdx = null;
}

function pickAutocomplete(matchIdx) {
  var match = acMatches[matchIdx];
  if (!match || acEntityIdx === null) return;
  var ent = entities[acEntityIdx];
  ent.canonical = match.canonical;
  ent.dictionary_id = match.id;
  ent.source = match.source;
  ent.entity_type = match.type;
  ent.match_type = 'manual';
  if (ent.status === 'new-entity') ent.status = 'auto-matched';
  hideAutocomplete();
  render();
}

function onCanonicalInput(idx, inputEl) {
  var query = inputEl.value.trim();
  if (query.length >= 2) {
    showAutocomplete(inputEl, idx, query);
  } else {
    hideAutocomplete();
  }
}

function onCanonicalKeydown(e, idx) {
  var dropdown = document.getElementById('autocomplete-dropdown');
  if (!dropdown || !dropdown.classList.contains('visible')) return;

  if (e.key === 'ArrowDown') {
    e.preventDefault();
    acActiveIdx = Math.min(acActiveIdx + 1, acMatches.length - 1);
    updateAcHighlight();
  } else if (e.key === 'ArrowUp') {
    e.preventDefault();
    acActiveIdx = Math.max(acActiveIdx - 1, 0);
    updateAcHighlight();
  } else if (e.key === 'Enter' && acActiveIdx >= 0) {
    e.preventDefault();
    pickAutocomplete(acActiveIdx);
  } else if (e.key === 'Escape') {
    hideAutocomplete();
  }
}

function updateAcHighlight() {
  var dropdown = document.getElementById('autocomplete-dropdown');
  var items = dropdown.querySelectorAll('.autocomplete-item');
  items.forEach(function(el, i) {
    el.classList.toggle('active', i === acActiveIdx);
  });
  if (acActiveIdx >= 0 && items[acActiveIdx]) {
    items[acActiveIdx].scrollIntoView({ block: 'nearest' });
  }
}

// --- Inline-edit autocomplete (shares dropdown + searchDictionary) ---
var inlineEditMatch = null;

function showInlineAutocomplete(inputEl, query) {
  var dropdown = document.getElementById('autocomplete-dropdown');
  acMatches = searchDictionary(query);
  acEntityIdx = null;          // not tied to an entity card
  acActiveIdx = -1;

  if (acMatches.length === 0) { hideAutocomplete(); return; }

  dropdown.innerHTML = acMatches.map(function(m, i) {
    return '<div class="autocomplete-item" data-idx="' + i + '"'
      + ' onmousedown="event.preventDefault(); pickInlineAutocomplete(' + i + ')">'
      + '<span class="ac-badge badge-' + m.type.toLowerCase() + '">' + m.type + '</span>'
      + '<span class="ac-text">'
      + '<span class="ac-canonical">' + highlightMatch(m.canonical, query) + '</span>'
      + (m.detail ? '<span class="ac-detail">' + escapeHtml(m.detail) + '</span>' : '')
      + '</span>'
      + '</div>';
  }).join('');

  var rect = inputEl.getBoundingClientRect();
  dropdown.style.left = rect.left + 'px';
  dropdown.style.top = (rect.bottom + 2) + 'px';
  dropdown.style.width = Math.max(rect.width, 250) + 'px';
  dropdown.classList.add('visible');
}

function pickInlineAutocomplete(matchIdx) {
  var match = acMatches[matchIdx];
  if (!match) return;
  var input = document.querySelector('.inline-edit-input');
  if (input) input.value = match.canonical;
  inlineEditMatch = match;
  hideAutocomplete();
}

// Close autocomplete when clicking outside
document.addEventListener('mousedown', function(e) {
  if (!e.target.closest('.autocomplete-dropdown')
      && !e.target.closest('.entity-correction input')
      && !e.target.closest('.inline-edit-input')) {
    hideAutocomplete();
  }
});

// ============================================================
// HELPERS
// ============================================================

function escapeHtml(str) {
  if (!str) return '';
  return str.replace(/&/g, '&amp;').replace(/</g, '&lt;')
    .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

// ============================================================
// COMBINED SSE PROCESSING (transcript correction + entity detection + LLM validation)
// ============================================================

var processingEventSource = null;
var processingSkipped = false;

function startProcessing() {
  var panel = document.getElementById('llm-log-panel');
  var overlay = document.getElementById('llm-overlay');
  var overlayText = document.getElementById('llm-overlay-text');
  var icon = document.getElementById('llm-log-icon');
  var status = document.getElementById('llm-log-status');
  var output = document.getElementById('llm-log-output');
  var overlaySub = document.getElementById('llm-overlay-sub');

  if (!panel) return;

  // Nothing to process if no NEEDS_PROCESSING flag
  if (typeof NEEDS_PROCESSING === 'undefined' || !NEEDS_PROCESSING) {
    // Already-saved transcripts: skip entirely
    if (typeof LLM_ENABLED !== 'undefined' && LLM_ENABLED) {
      panel.classList.add('visible');
      icon.classList.add('done');
      status.textContent = 'skipped';
      var line = document.createElement('div');
      line.className = 'llm-line info';
      line.textContent = 'Skipped — using saved data';
      output.appendChild(line);
    }
    return;
  }

  // Skip on already-reviewed transcripts
  if (typeof TRANSCRIPT_STATUS !== 'undefined' && (TRANSCRIPT_STATUS === 'submitted' || TRANSCRIPT_STATUS === 'processed')) {
    panel.classList.add('visible');
    icon.classList.add('done');
    status.textContent = 'skipped';
    var line = document.createElement('div');
    line.className = 'llm-line info';
    line.textContent = 'Skipped — transcript already ' + TRANSCRIPT_STATUS;
    output.appendChild(line);
    return;
  }

  panel.classList.add('visible');
  icon.classList.add('running');
  status.textContent = 'connecting...';
  overlay.classList.add('visible');
  if (overlayText) overlayText.textContent = 'Preparing...';
  if (overlaySub) overlaySub.textContent = 'Connecting to processing pipeline';

  processingEventSource = new EventSource('/api/transcripts/' + TRANSCRIPT_ID + '/process');

  processingEventSource.addEventListener('correction', function(e) {
    if (processingSkipped) return;
    var data = JSON.parse(e.data);

    // Update transcript with corrected text
    rawTranscript = data.text;

    // Build inline edits from LLM corrections
    if (data.corrections && data.corrections.length > 0) {
      data.corrections.forEach(function(c) {
        inlineEdits.push({
          start: c.start,
          end: c.end,
          oldWord: c.original,
          newWord: c.corrected,
          source: 'llm',
          reason: c.reason
        });
      });
    }

    // Build and show banner combining dictionary + LLM corrections
    var bannerParts = [];
    var dictCorr = data.applied_corrections || [];
    if (dictCorr.length > 0) {
      var totalCount = dictCorr.reduce(function(sum, c) { return sum + c.count; }, 0);
      var details = dictCorr.map(function(c) {
        return c.original + ' \u2192 ' + c.corrected + (c.count > 1 ? ' (\u00d7' + c.count + ')' : '');
      }).join(', ');
      bannerParts.push(totalCount + ' auto-correction' + (totalCount !== 1 ? 's' : '') + ': ' + details);
    }
    if (data.corrections && data.corrections.length > 0) {
      var llmDetails = data.corrections.map(function(c) {
        return c.original + ' \u2192 ' + c.corrected;
      }).join(', ');
      bannerParts.push(data.corrections.length + ' LLM correction' + (data.corrections.length !== 1 ? 's' : '') + ': ' + llmDetails);
    }
    if (bannerParts.length > 0) {
      var bannerText = document.getElementById('auto-corrections-text');
      var banner = document.getElementById('auto-corrections-banner');
      if (bannerText && banner) {
        bannerText.textContent = bannerParts.join(' | ');
        banner.style.display = '';
      }
    }

    render();

    // Update overlay for next phase
    if (overlayText) overlayText.textContent = 'Checking fluency...';
  });

  processingEventSource.addEventListener('fluency', function(e) {
    if (processingSkipped) return;
    var data = JSON.parse(e.data);

    if (data.issues && data.issues.length > 0) {
      fluencyIssues = data.issues;
      render();
    }

    if (overlayText) overlayText.textContent = 'Detecting entities...';
  });

  processingEventSource.addEventListener('entities', function(e) {
    if (processingSkipped) return;
    var newEntities = JSON.parse(e.data);
    entities = newEntities;
    render();

    // Update overlay for next phase
    if (overlayText) overlayText.textContent = 'Validating entities...';
  });

  processingEventSource.addEventListener('log', function(e) {
    var data = JSON.parse(e.data);
    var line = document.createElement('div');
    line.className = 'llm-line ' + (data.level || 'info');
    if (data.entity_start !== undefined) {
      line.classList.add('llm-line-clickable');
      line.dataset.entityStart = data.entity_start;
      line.dataset.entityEnd = data.entity_end;
      line.onclick = function() {
        var s = parseInt(this.dataset.entityStart);
        var e = parseInt(this.dataset.entityEnd);
        var idx = entities.findIndex(function(ent) { return ent.start === s && ent.end === e; });
        if (idx >= 0) selectEntity(idx);
      };
    }
    line.textContent = data.message;
    output.appendChild(line);
    output.scrollTop = output.scrollHeight;

    // Mirror log messages to overlay subtitle so user sees progress
    if (overlaySub) overlaySub.textContent = data.message;

    status.textContent = 'running...';
  });

  processingEventSource.addEventListener('result', function(e) {
    processingEventSource.close();
    processingEventSource = null;

    icon.classList.remove('running');
    icon.classList.add('done');
    status.textContent = 'done';
    overlay.classList.remove('visible');

    if (!processingSkipped) {
      var newEntities = JSON.parse(e.data);
      entities = newEntities;
      render();
    }

    var line = document.createElement('div');
    line.className = 'llm-line ok';
    line.textContent = '--- processing complete ---';
    output.appendChild(line);
    output.scrollTop = output.scrollHeight;
  });

  processingEventSource.addEventListener('error', function(e) {
    if (processingEventSource) {
      processingEventSource.close();
      processingEventSource = null;
    }
    icon.classList.remove('running');
    icon.classList.add('error');
    status.textContent = 'error';
    overlay.classList.remove('visible');

    var line = document.createElement('div');
    line.className = 'llm-line error';
    line.textContent = 'Connection to processing pipeline lost';
    output.appendChild(line);
  });
}

function skipProcessing() {
  processingSkipped = true;
  if (processingEventSource) {
    processingEventSource.close();
    processingEventSource = null;
  }
  var overlay = document.getElementById('llm-overlay');
  var icon = document.getElementById('llm-log-icon');
  var status = document.getElementById('llm-log-status');
  var output = document.getElementById('llm-log-output');

  if (overlay) overlay.classList.remove('visible');
  if (icon) { icon.classList.remove('running'); icon.classList.add('error'); }
  if (status) status.textContent = 'skipped';

  var line = document.createElement('div');
  line.className = 'llm-line warn';
  line.textContent = '--- skipped by user ---';
  if (output) output.appendChild(line);
}

function toggleLlmLog() {
  var panel = document.getElementById('llm-log-panel');
  if (panel) panel.classList.toggle('collapsed');
}

// ============================================================
// CALENDAR
// ============================================================

function fetchCalendarEvents() {
  if (typeof TRANSCRIPT_DATE === 'undefined' || !TRANSCRIPT_DATE) return;

  var loading = document.getElementById('calendar-loading');
  var eventsEl = document.getElementById('calendar-events');
  var fyiEl = document.getElementById('calendar-fyi');
  var countEl = document.getElementById('calendar-event-count');

  fetch('/api/calendar/' + TRANSCRIPT_DATE)
    .then(function(r) { return r.json(); })
    .then(function(data) {
      if (loading) loading.style.display = 'none';

      if (data.error || !data.events || data.events.length === 0) {
        if (eventsEl) {
          eventsEl.innerHTML = '<div class="calendar-empty">'
            + (data.error ? 'Could not load schedule' : 'No events for this date')
            + '</div>';
        }
        if (countEl) countEl.textContent = '';
        return;
      }

      renderCalendarEvents(data.events, eventsEl, fyiEl, countEl);
    })
    .catch(function(err) {
      console.error('Calendar fetch failed:', err);
      if (loading) loading.style.display = 'none';
      if (eventsEl) {
        eventsEl.innerHTML = '<div class="calendar-empty">Could not load schedule</div>';
      }
    });
}

function renderCalendarEvents(events, eventsEl, fyiEl, countEl) {
  var scheduled = [];
  var fyi = [];

  events.forEach(function(ev) {
    // All-day "free" events (vacations etc.) go to FYI
    var isAllDay = !ev.start || ev.start.indexOf('T') === -1;
    var isFree = ev.showAs === 'free';
    if (isAllDay || isFree) {
      fyi.push(ev);
    } else {
      scheduled.push(ev);
    }
  });

  if (countEl) {
    countEl.textContent = scheduled.length + ' event' + (scheduled.length !== 1 ? 's' : '');
  }

  if (eventsEl) {
    if (scheduled.length === 0) {
      eventsEl.innerHTML = '<div class="calendar-empty">No scheduled events</div>';
    } else {
      eventsEl.innerHTML = scheduled.map(function(ev) {
        var startTime = formatTime(ev.start);
        var endTime = formatTime(ev.end);
        var tentativeClass = ev.showAs === 'tentative' ? ' tentative' : '';
        var attendeeHtml = ev.attendees.length > 0
          ? '<span class="cal-attendees">' + ev.attendees.map(escapeHtml).join(', ') + '</span>'
          : '';

        return '<div class="calendar-event' + tentativeClass + '">'
          + '<span class="cal-time">' + startTime + ' - ' + endTime + '</span>'
          + '<span class="cal-subject">' + escapeHtml(ev.subject) + '</span>'
          + attendeeHtml
          + '</div>';
      }).join('');
    }
  }

  if (fyiEl && fyi.length > 0) {
    fyiEl.innerHTML = '<div class="calendar-fyi-header">FYI (free / all-day)</div>'
      + fyi.map(function(ev) {
        return '<div class="calendar-event free">'
          + '<span class="cal-subject">' + escapeHtml(ev.subject) + '</span>'
          + '</div>';
      }).join('');
  }
}

function formatTime(isoStr) {
  if (!isoStr) return '--:--';
  var match = isoStr.match(/T(\d{2}):(\d{2})/);
  if (!match) return '--:--';
  return match[1] + ':' + match[2];
}

function toggleCalendar() {
  var panel = document.getElementById('calendar-panel');
  if (panel) panel.classList.toggle('collapsed');
}

// ============================================================
// INLINE WORD CORRECTION (double-click)
// ============================================================

// Track inline edits: [{start, end, oldWord, newWord}]
// May already be declared in review.html with LLM corrections pre-populated
if (typeof inlineEdits === 'undefined') { var inlineEdits = []; }

// Track fluency issues: [{start, end, text, category, note}]
if (typeof fluencyIssues === 'undefined') { var fluencyIssues = []; }

(function() {
  var transcriptEl = document.getElementById('transcript');
  if (!transcriptEl) return;

  transcriptEl.addEventListener('dblclick', function(e) {
    // Double-click on an active (non-dismissed) entity → select it in sidebar
    var entitySpan = e.target.closest('.entity-highlight:not(.dismissed)');
    if (entitySpan && entitySpan.dataset.idx !== undefined) {
      e.preventDefault();
      selectEntity(parseInt(entitySpan.dataset.idx));
      return;
    }

    // Trigger on plain text spans and dismissed entity highlights
    var dismissedSpan = e.target.closest('.entity-highlight.dismissed');
    var span = dismissedSpan || e.target.closest('.plain-text');
    if (!span) return;

    // Check if we have a saved multi-word selection (preserved from mousedown
    // before the browser cleared it)
    var useSelection = false;
    var selAbsStart, selAbsEnd, selText;
    if (savedMultiWordSelection) {
      useSelection = true;
      selAbsStart = savedMultiWordSelection.start;
      selAbsEnd = savedMultiWordSelection.end;
      selText = savedMultiWordSelection.text;
      savedMultiWordSelection = null;
    }

    e.preventDefault();
    window.getSelection().removeAllRanges();
    hideSelectionPopup();

    var absWordStart, absWordEnd, word;

    if (useSelection) {
      // Use the full multi-word selection
      absWordStart = selAbsStart;
      absWordEnd = selAbsEnd;
      word = selText;
    } else {
      // Single word: find word under cursor
      var spanStart = parseInt(span.dataset.start);
      var spanEnd = parseInt(span.dataset.end);

      var range = document.caretRangeFromPoint(e.clientX, e.clientY);
      if (!range || range.startContainer.nodeType !== Node.TEXT_NODE) return;

      var textNode = range.startContainer;
      var clickOffset = range.startOffset;
      var nodeText = textNode.textContent;

      var wordStart = clickOffset;
      var wordEnd = clickOffset;
      while (wordStart > 0 && !/\s/.test(nodeText[wordStart - 1])) wordStart--;
      while (wordEnd < nodeText.length && !/\s/.test(nodeText[wordEnd])) wordEnd++;

      word = nodeText.substring(wordStart, wordEnd).trim();
      if (!word) return;

      var charsBefore = 0;
      var walker = document.createTreeWalker(span, NodeFilter.SHOW_TEXT);
      var current;
      while ((current = walker.nextNode())) {
        if (current === textNode) break;
        charsBefore += current.textContent.length;
      }
      absWordStart = spanStart + charsBefore + wordStart;
      absWordEnd = spanStart + charsBefore + wordEnd;
    }

    // Create inline input
    var input = document.createElement('input');
    input.type = 'text';
    input.className = 'inline-edit-input';
    input.value = word;
    input.dataset.absStart = absWordStart;
    input.dataset.absEnd = absWordEnd;
    input.dataset.originalWord = word;

    if (useSelection) {
      // For multi-word: replace the entire selection range in the transcript panel
      // Find all text/element nodes in the transcript that fall within the range
      var transcriptEl = document.getElementById('transcript');
      var editRange = document.createRange();

      // Find start and end nodes by walking the transcript
      function findNodeAtOffset(container, targetOffset) {
        var spans = container.querySelectorAll('[data-start]');
        for (var si = 0; si < spans.length; si++) {
          var s = spans[si];
          var sStart = parseInt(s.dataset.start);
          var sEnd = parseInt(s.dataset.end);
          if (targetOffset >= sStart && targetOffset <= sEnd) {
            var localTarget = targetOffset - sStart;
            var tw = document.createTreeWalker(s, NodeFilter.SHOW_TEXT);
            var tn, acc = 0;
            while ((tn = tw.nextNode())) {
              if (acc + tn.textContent.length >= localTarget) {
                return { node: tn, offset: localTarget - acc };
              }
              acc += tn.textContent.length;
            }
          }
        }
        return null;
      }

      var startInfo = findNodeAtOffset(transcriptEl, absWordStart);
      var endInfo = findNodeAtOffset(transcriptEl, absWordEnd);

      if (startInfo && endInfo) {
        editRange.setStart(startInfo.node, startInfo.offset);
        editRange.setEnd(endInfo.node, endInfo.offset);
        editRange.deleteContents();
        editRange.insertNode(input);
      } else {
        // Fallback: just re-render with the input appended
        return;
      }
    } else {
      // Single word: replace the word in the text node with the input
      var beforeText = document.createTextNode(nodeText.substring(0, wordStart));
      var afterText = document.createTextNode(nodeText.substring(wordEnd));
      var parent = textNode.parentNode;
      parent.insertBefore(beforeText, textNode);
      parent.insertBefore(input, textNode);
      parent.insertBefore(afterText, textNode);
      parent.removeChild(textNode);
    }

    // Size input to fit content
    input.style.width = Math.max(40, word.length * 9 + 16) + 'px';
    input.addEventListener('input', function() {
      input.style.width = Math.max(40, input.value.length * 9 + 16) + 'px';
    });

    input.focus();
    input.select();

    // Reset inline autocomplete state
    inlineEditMatch = null;

    // Show autocomplete as user types
    input.addEventListener('input', function() {
      var q = input.value.trim();
      if (q.length >= 2) {
        showInlineAutocomplete(input, q);
      } else {
        hideAutocomplete();
      }
    });

    var committed = false;

    function commitEdit() {
      if (committed) return;
      committed = true;

      hideAutocomplete();

      var newWord = input.value.trim();
      var absStart = parseInt(input.dataset.absStart);
      var absEnd = parseInt(input.dataset.absEnd);
      var oldWord = input.dataset.originalWord;
      var matchedEntity = inlineEditMatch;
      inlineEditMatch = null;

      if (newWord !== oldWord) {
        // Splice new word into rawTranscript
        rawTranscript = rawTranscript.substring(0, absStart) + newWord + rawTranscript.substring(absEnd);

        var delta = newWord.length - oldWord.length;

        // Remove inline edits that overlap with the edited range, then shift the rest
        inlineEdits = inlineEdits.filter(function(ed) {
          return ed.end <= absStart || ed.start >= absEnd;
        });
        if (delta !== 0) {
          inlineEdits.forEach(function(ed) {
            if (ed.start >= absEnd) {
              ed.start += delta;
              ed.end += delta;
            }
          });
        }

        // Adjust entity positions
        entities.forEach(function(ent) {
          if (ent.start >= absEnd) {
            // Entity starts after the edit — shift both
            if (delta !== 0) { ent.start += delta; ent.end += delta; }
          } else if (ent.start <= absStart && ent.end >= absEnd) {
            // Edit is inside this entity — adjust end and update text
            if (delta !== 0) { ent.end += delta; }
            ent.original_text = rawTranscript.substring(ent.start, ent.end);
          } else if (ent.start > absStart) {
            if (delta !== 0) { ent.end += delta; }
          }
        });

        // Adjust fluency issue positions
        if (delta !== 0) {
          fluencyIssues = fluencyIssues.filter(function(f) {
            return f.end <= absStart || f.start >= absEnd;
          });
          fluencyIssues.forEach(function(f) {
            if (f.start >= absEnd) { f.start += delta; f.end += delta; }
          });
        }

        if (matchedEntity) {
          // Create a proper entity from the autocomplete match
          var newEntity = {
            start: absStart,
            end: absStart + newWord.length,
            original_text: oldWord,
            canonical: matchedEntity.canonical,
            entity_type: matchedEntity.type,
            match_type: 'manual',
            confidence: 'high',
            status: 'auto-matched',
            dictionary_id: matchedEntity.id,
            source: matchedEntity.source,
            role: '',
            candidates: []
          };

          // Remove dismissed entities overlapping the new range
          entities = entities.filter(function(e) {
            return !(e.status === 'dismissed' && e.start < newEntity.end && e.end > newEntity.start);
          });

          entities.push(newEntity);
          entities.sort(function(a, b) { return a.start - b.start; });

          // Deduplicate overlapping entities
          var deduped = [];
          var lastEnd = -1;
          entities.forEach(function(d) {
            if (d.start >= lastEnd) { deduped.push(d); lastEnd = d.end; }
          });
          entities = deduped;

          // Activate the new entity card
          var newIdx = entities.findIndex(function(e) {
            return e.start === newEntity.start && e.end === newEntity.end;
          });
          activeEntityIdx = newIdx;
        } else {
          // No dictionary match — record as inline edit highlight
          inlineEdits.push({ start: absStart, end: absStart + newWord.length, oldWord: oldWord, newWord: newWord });
        }
      }

      hideSelectionPopup();
      render();

      if (matchedEntity) {
        requestAnimationFrame(function() {
          requestAnimationFrame(function() { scrollSidebarToActiveCard(); });
        });
      }
    }

    function cancelEdit() {
      if (committed) return;
      committed = true;
      hideAutocomplete();
      hideSelectionPopup();
      render();
    }

    input.addEventListener('keydown', function(ev) {
      var dropdown = document.getElementById('autocomplete-dropdown');
      var acVisible = dropdown && dropdown.classList.contains('visible');

      if (acVisible) {
        if (ev.key === 'ArrowDown') {
          ev.preventDefault();
          acActiveIdx = Math.min(acActiveIdx + 1, acMatches.length - 1);
          updateAcHighlight();
          return;
        } else if (ev.key === 'ArrowUp') {
          ev.preventDefault();
          acActiveIdx = Math.max(acActiveIdx - 1, 0);
          updateAcHighlight();
          return;
        } else if (ev.key === 'Enter' && acActiveIdx >= 0) {
          ev.preventDefault();
          pickInlineAutocomplete(acActiveIdx);
          return;
        } else if (ev.key === 'Escape') {
          ev.preventDefault();
          hideAutocomplete();
          return;
        }
      }

      if (ev.key === 'Enter') { ev.preventDefault(); commitEdit(); }
      else if (ev.key === 'Escape') { ev.preventDefault(); cancelEdit(); }
    });
    input.addEventListener('blur', function() {
      commitEdit();
    });
  });
})();

// ============================================================
// INIT
// ============================================================

if (typeof rawTranscript !== 'undefined' && typeof entities !== 'undefined') {
  loadDictionary();
  render();
  startProcessing();
  fetchCalendarEvents();
}
